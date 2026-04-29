#!/usr/bin/env bash
# Tier 3 substitutions for mqube-architect.
#
# Three adjustments needed for local Tier 3:
#
# 1. Dockerfile FROM is jx3mqubebuild.azurecr.io/docker-io/library/alpine:3.21
#    (private mirror — needs az acr login). The Dockerfile literally has a
#    commented-out `FROM alpine:3.16` with the note "replace with the
#    commented base image if building locally". Our psl_build hook does
#    that swap and also builds the Go binary natively for arm64 (faster
#    than emulated multi-stage build).
#
# 2. Two Secrets the chart references but doesn't define (provided by the
#    skipped `dev/preview-infrastructure` chart in real previews):
#    `architect` (15 keys: Azure/MongoDB/GitHub/Slack creds + the GitHub-
#    App private key Secret-volume mount) and `redis` (connection-string).
#
# 3. Backing services: WITH_MONGO + WITH_REDIS run a single-pod mongo:7
#    and redis:7-alpine in the namespace. Secret values point at those
#    Service hostnames so the app can actually connect. NOTE: the chart's
#    default `config.redis.masterName: mymaster` switches the app's redis
#    client into sentinel mode; our plain redis pod doesn't speak sentinel.
#    The app gets past redis init only if you also override the chart's
#    config to remove masterName — out of scope for the harness, doable
#    in a `psl_post` patch on the rendered ConfigMap if you want to chase it.

# Opt into common backing services.
export WITH_MONGO=1
export WITH_REDIS=1

# shellcheck disable=SC2034  # PSL_SELECTOR is read by preview-up.sh after sourcing.
PSL_SELECTOR="name=preview"

psl_build() {
  local img="$1"
  local tmp
  tmp=$(mktemp -d)

  echo "[psl_build] go build linux/arm64 binary..."
  (cd "$REPO" \
    && CGO_ENABLED=0 GOOS=linux GOARCH=arm64 \
       go build -o "$tmp/mqube-architect" ./cmd/api/) || return 1

  cp -R "$REPO/docs" "$tmp/docs"
  cat > "$tmp/Dockerfile" <<'EOF'
FROM alpine:3.21
RUN apk upgrade --no-cache && apk --no-cache add git ca-certificates
COPY mqube-architect /
COPY docs/swagger.json /docs/swagger.json
RUN addgroup -S nonroot && adduser -S nonroot -G nonroot
USER nonroot
CMD ["./mqube-architect"]
EOF

  echo "[psl_build] docker build (public alpine base)..."
  (cd "$tmp" && docker build -t "$img" . 2>&1 | tail -2)
  rm -rf "$tmp"
}

psl_pre() {
  local ns="$1"
  $K -n "$ns" create secret generic architect \
    --from-literal=azure-client-id=stub \
    --from-literal=azure-client-secret=stub \
    --from-literal=azure-subscription-id=stub \
    --from-literal=azure-tenant-id=stub \
    --from-literal=db-configs=stub \
    --from-literal=git-user-email=stub \
    --from-literal=git-user-name=stub \
    --from-literal=git-user-token=stub \
    --from-literal=github-webhook-secret=stub \
    --from-literal=gh-app-private-key=stub \
    --from-literal=mongodb-connection-string='mongodb://mongodb:27017/architect' \
    --from-literal=mongodb-org-id=stub \
    --from-literal=mongodb-private-key=stub \
    --from-literal=mongodb-public-key=stub \
    --from-literal=slack-API-token=stub \
    --dry-run=client -o yaml | $K apply -f - >/dev/null
  $K -n "$ns" create secret generic redis \
    --from-literal=connection-string='' \
    --dry-run=client -o yaml | $K apply -f - >/dev/null
}

# psl_post runs AFTER helmfile sync (which times out at wait:true because the
# pod CrashLoops on chart-config issues). Patches the deployed ConfigMap to:
#   - Switch redis to standard (non-sentinel) mode by adding url+port and
#     leaving REDIS_SENTINELS empty (the wrapper picks standard if env empty).
#   - Disable github integration (chart hardcodes enabled:true which forces
#     parsing gh-app-private-key as a real PEM; our stub isn't valid).
#
# Three findings worth shifting left into the chart itself:
#   - Chart should expose a knob to disable redis-sentinel mode.
#   - Chart's redis section should default url/port (or read them from a
#     redis Service in the namespace).
#   - github.enabled should be false-by-default OR chart should validate
#     the gh-app-private-key Secret before requiring it.
psl_post() {
  local ns="$1"

  echo "[psl_post] patching ConfigMap mqube-architect-config (redis standard mode + github off)"
  local cm
  cm=$($K -n "$ns" get cm mqube-architect-config -o jsonpath='{.data.config\.yaml}' 2>/dev/null) || return 0
  cm=$(echo "$cm" | awk '
    /^redis:$/ { print "redis:"; print "  url: redis"; print "  port: 6379"; print "  db: 0"; print "  poolSize: 25"; in_redis=1; next }
    in_redis && /^[a-zA-Z]/ { in_redis=0 }
    in_redis { next }
    /^github:$/ { in_gh=1; print; next }
    in_gh && /^  enabled:/ { print "  enabled: false"; next }
    in_gh && /^[a-zA-Z]/ { in_gh=0 }
    { print }
  ')
  $K -n "$ns" create cm mqube-architect-config --from-literal=config.yaml="$cm" \
    --dry-run=client -o yaml | $K apply -f - >/dev/null

  echo "[psl_post] rolling architect to pick up new config..."
  $K -n "$ns" rollout restart deploy preview-mqube-architect >/dev/null 2>&1 || true
  $K -n "$ns" rollout status deploy preview-mqube-architect --timeout 60s 2>&1 | tail -3
}
