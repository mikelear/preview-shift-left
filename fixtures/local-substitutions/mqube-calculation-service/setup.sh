#!/usr/bin/env bash
# Tier 3 substitutions for mqube-calculation-service.
#
# Two cluster-side dependencies don't resolve locally:
#
# 1. dev/mpowered-calculation-config (OCI chart from jx3mqubebuild.azurecr.io)
#    — needs az acr login + cluster credentials. We skip it via PSL_SELECTOR
#    and stub the secrets it'd otherwise provide directly. The chart's actual
#    job (config-loader sidecar pulling tenant config from git) doesn't run
#    here, but the consumer pod can still start.
#
# 2. backend-service-oauth + github-config Secrets — referenced by envFrom
#    in the deployment template. Real preview gets these via mpowered-
#    calculation-config (above) or jx-secret-replicate from the dev namespace.
#    Stub values let the pod schedule + start; OAuth/GitHub calls fail at
#    runtime but that's a runtime concern, not a deploy concern.

# Skip the private OCI chart dep — sync only the consumer's own chart.
PSL_SELECTOR="name=preview"

psl_pre() {
  local ns="$1"
  echo "[psl_pre] stubbing secrets that mpowered-calculation-config would provide"

  $K -n "$ns" create secret generic backend-service-oauth \
    --from-literal=BASE_URL=http://stub-oauth.local \
    --from-literal=CLIENT_ID=local-stub-client \
    --from-literal=CLIENT_SECRET=local-stub-secret \
    --dry-run=client -o yaml | $K apply -f - >/dev/null

  $K -n "$ns" create secret generic github-config \
    --from-literal=github-token=stub \
    --dry-run=client -o yaml | $K apply -f - >/dev/null

  # Stub the ConfigMap that the skipped chart would have created. The
  # deployment mounts this as a volume (not just envFrom), so missing it
  # blocks the init container's volume mount and pod stays in Init:0/1.
  $K -n "$ns" create configmap mpowered-calculation-config-loader-configmap \
    --from-literal=placeholder=stub \
    --dry-run=client -o yaml | $K apply -f - >/dev/null
}
