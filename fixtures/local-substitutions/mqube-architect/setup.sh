#!/usr/bin/env bash
# Tier 3 substitutions for mqube-architect.
#
# Two adjustments needed for local Tier 3:
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
#    `architect` (14 keys: Azure/MongoDB/GitHub/Slack creds) and `redis`
#    (connection-string). Stub values let the pod start; runtime calls to
#    those services will fail but that's expected for a local preview.

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
    --from-literal=mongodb-connection-string=stub \
    --from-literal=mongodb-org-id=stub \
    --from-literal=mongodb-private-key=stub \
    --from-literal=mongodb-public-key=stub \
    --from-literal=slack-API-token=stub \
    --dry-run=client -o yaml | $K apply -f - >/dev/null
  $K -n "$ns" create secret generic redis \
    --from-literal=connection-string=stub \
    --dry-run=client -o yaml | $K apply -f - >/dev/null
}
