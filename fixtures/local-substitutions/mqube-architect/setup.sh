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
    --from-literal=connection-string=redis:6379 \
    --dry-run=client -o yaml | $K apply -f - >/dev/null
}
