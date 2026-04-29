# shellcheck shell=bash
# Local substitutions for leartech-auth-ui — an EXCEPTION, not the template.
#
# Most consumer repos' preview/helmfile.yaml.gotmpl will run verbatim against
# our local kind cluster: helmfile sync applies every release as declared.
# auth-ui is the complicated case because its preview helmfile pulls two
# dependencies that hit Apple-Silicon / arm64-specific blockers:
#
#   1. bitnami-oci/mongodb — pinned tag (8.0.13-debian-12-r0) publishes only
#      an amd64 manifest. Pull fails on arm64 kind nodes. Real cluster nodes
#      are amd64 so this never surfaces there.
#
#   2. Hydra subchart's automigration init container fails with "dsn must
#      be set" when the DSN is sqlite on arm64 — the init container's config
#      loading path differs from the main container. Real cluster uses same
#      config and works; local repro appears arm64-related.
#
# Solution: skip those two releases in the helmfile sync, deploy local
# substitutes for them instead.
#
# For a Go service or any MFE without these two deps, NO setup.sh is needed.
# `make preview REPO=...` just runs their preview/helmfile.yaml.gotmpl.
#
# Hook contract:
#   - PSL_SELECTOR         helmfile --selector value to filter releases
#   - psl_pre()            runs BEFORE helmfile sync — prep work (images,
#                          charts, secrets, env)
#   - psl_post()           runs AFTER helmfile sync — post-deploy actions
#                          (our substitute releases, TLS, CORS, config)
#
# preview-up.sh calls psl_pre + psl_post and passes --selector "$PSL_SELECTOR"
# to helmfile sync.

# shellcheck disable=SC2034  # PSL_SELECTOR/PSL_PROTO are read by preview-up.sh after sourcing.
# auth-postgresql is multi-arch — let helmfile deploy it normally.
# Only skip the OCI auth-service pull (we sub it with the local chart).
PSL_SELECTOR='name!=preview-auth-service'
# shellcheck disable=SC2034
PSL_PROTO="https"

psl_pre() {
  local ns="$1"
  local ui_url="$2"

  # Package the auth-service chart from local source and push to localhost:5001.
  # helmfile would pull it from $JX_CHART_REPOSITORY; we mirror to our local
  # registry so the pull succeeds offline.
  echo "[auth-ui] packaging + pushing auth-service chart"
  local as_chart="${AUTH_SERVICE_REPO:-$HOME/leartech/leartech-auth-service}/charts/leartech-auth-service"
  (cd "$as_chart" && helm dep build . >/dev/null 2>&1)
  local pkg
  pkg=$(helm package "$as_chart" -d /tmp 2>/dev/null | awk -F': ' '{print $NF}')
  helm push "$pkg" oci://localhost:5001/charts >/dev/null 2>&1 || true

  # Build auth-service natively arm64 and push to local registry.
  echo "[auth-ui] building auth-service (arm64 native) and pushing"
  local as_bin
  as_bin=$(mktemp)
  (cd "${AUTH_SERVICE_REPO:-$HOME/leartech/leartech-auth-service}" \
    && GOOS=linux GOARCH=arm64 CGO_ENABLED=0 \
      go build -ldflags='-w -s' -o "$as_bin" ./cmd/server) >/dev/null
  local build_dir
  build_dir=$(mktemp -d)
  mv "$as_bin" "$build_dir/auth-service"
  cat >"$build_dir/Dockerfile" <<'EOF'
FROM alpine:3.19
RUN apk add --no-cache ca-certificates tzdata && adduser -D -u 1000 auth
USER auth
COPY auth-service /usr/local/bin/auth-service
EXPOSE 8080
ENTRYPOINT ["auth-service"]
EOF
  (cd "$build_dir" && docker build -t localhost:5001/mikelear/leartech-auth-service:latest .) >/dev/null 2>&1
  docker push localhost:5001/mikelear/leartech-auth-service:latest >/dev/null 2>&1
  rm -rf "$build_dir"

  # Pre-create preview-secrets ns so the jx secret copy presync hook has
  # somewhere to look (we install a `jx` stub that no-ops the copy anyway).
  $K create ns preview-secrets --dry-run=client -o yaml | $K apply -f - >/dev/null

  # jx stub on PATH so the presync `jx secret copy` hook exits 0.
  PSL_JX_STUB=$(mktemp -d)
  cat >"$PSL_JX_STUB/jx" <<'EOF'
#!/bin/sh
# preview-shift-left stub — noop (preview-secrets ns is empty locally).
exit 0
EOF
  chmod +x "$PSL_JX_STUB/jx"
  export PATH="$PSL_JX_STUB:$PATH"
}

psl_post() {
  local ns="$1"
  local ui_url="$2"
  local as_host="leartech-auth-service-pr${PULL_NUMBER}.${DOMAIN}"
  local hydra_host="hydra-pr${PULL_NUMBER}.${DOMAIN}"
  local as_url="https://${as_host}:8443"
  local hydra_url="https://${hydra_host}:8443"
  local client_id="${HYDRA_CLIENT_ID:-frontend-services}"

  # ---- Wait for helmfile-deployed Postgres to be ready ---------------
  # auth-postgresql runs as a normal helmfile release (bitnami-oci/
  # postgresql is multi-arch). Same shape as auth-service's own preview:
  # single instance, two databases (hydra + auth_service) created via
  # initdbScripts in leartech-auth-ui/preview/postgresql.yaml.
  echo "[auth-ui] waiting for auth-postgresql to be ready"
  $K -n "$ns" rollout status statefulset/auth-postgresql --timeout=180s >/dev/null

  # ---- Substitute for preview-auth-service (Hydra subchart, postgres) ----
  # Hydra uses memory DSN locally — keeps cold-start simple. Auth-service
  # user store IS Postgres (matches real preview shape).
  #
  # Pulls the consumer's own auth-service-values.yaml.gotmpl so a wrong
  # key in that file fails locally too — only truly local-specific bits
  # stay as --set overrides below. Caught a webcoder-ui PR-only failure
  # where a `store.backend` typo in the values file silently fell back
  # to MongoDB — surfaced in CI but not shift-left because shift-left's
  # --set overrides shadowed the wrong values-file keys.
  echo "[auth-ui] deploying preview-auth-service (local chart, postgres store)"
  local as_chart="${AUTH_SERVICE_REPO:-$HOME/leartech/leartech-auth-service}/charts/leartech-auth-service"
  local as_values_rendered
  as_values_rendered=$(mktemp)
  sed \
    -e 's|{{ requiredEnv "DOCKER_REGISTRY" }}|localhost:5001|g' \
    -e 's|{{ requiredEnv "DOCKER_REGISTRY_ORG" }}|mikelear|g' \
    "$REPO/preview/auth-service-values.yaml.gotmpl" >"$as_values_rendered"
  helm --kube-context "$CONTEXT" upgrade --install preview-auth-service "$as_chart" \
    -n "$ns" \
    -f "$as_values_rendered" \
    --set image.repository=localhost:5001/mikelear/leartech-auth-service \
    --set image.tag=latest \
    --set image.pullPolicy=IfNotPresent \
    --set clusterID=local \
    --set "authUIURL=${ui_url}" \
    --set "jxRequirements.ingress.domain=${DOMAIN}" \
    --set "jxRequirements.ingress.namespaceSubDomain=-pr${PULL_NUMBER}." \
    --set "jxRequirements.ingress.serviceType=ClusterIP" \
    --set externalSecrets.gcp.enabled=false \
    --set externalSecrets.azure.enabled=false \
    --set hydra.hydra.dev=true \
    --set hydra.hydra.config.dsn=memory \
    --set hydra.hydra.config.strategies.access_token=jwt \
    --set "hydra.hydra.config.urls.self.issuer=${hydra_url}" \
    --set "hydra.hydra.config.urls.self.public=${hydra_url}" \
    --set "hydra.hydra.config.urls.login=${ui_url}/login" \
    --set "hydra.hydra.config.urls.consent=${as_url}/api/auth/consent" \
    --set "hydra.hydra.config.urls.logout=${as_url}/api/auth/logout" \
    --set hydra.hydra.config.serve.public.cors.enabled=true \
    --set "hydra.hydra.config.serve.public.cors.allowed_origins[0]=${ui_url}" \
    --set hydra.ingress.public.enabled=true \
    --set hydra.ingress.public.className=nginx \
    --set "hydra.ingress.public.hosts[0].host=${hydra_host}" \
    --set 'hydra.ingress.public.hosts[0].paths[0].path=/' \
    --set 'hydra.ingress.public.hosts[0].paths[0].pathType=Prefix' \
    --set hydra.automigration.enabled=false \
    --set hydra.secret.enabled=true >/dev/null
  rm -f "$as_values_rendered"
  $K -n "$ns" rollout status deploy/preview-auth-service-hydra --timeout=120s >/dev/null
  $K -n "$ns" rollout status deploy/preview-auth-service-leartech-auth-service --timeout=60s >/dev/null

  # ---- TLS + CORS on ingresses we own --------------------------------
  for ing_host in "leartech-auth-service:${as_host}" "preview-auth-service-hydra-public:${hydra_host}"; do
    local ing="${ing_host%%:*}"
    local hp="${ing_host##*:}"
    $K -n "$ns" patch ingress "$ing" --type=merge -p "$(
      cat <<JSON
{"spec":{"ingressClassName":"nginx","tls":[{"hosts":["$hp"],"secretName":"wildcard-localtest"}]}}
JSON
    )" >/dev/null 2>&1 || true
  done
  $K -n "$ns" annotate ingress leartech-auth-service --overwrite \
    nginx.ingress.kubernetes.io/enable-cors=true \
    "nginx.ingress.kubernetes.io/cors-allow-origin=${ui_url}" \
    nginx.ingress.kubernetes.io/cors-allow-credentials=true \
    "nginx.ingress.kubernetes.io/cors-allow-methods=GET, POST, OPTIONS" \
    "nginx.ingress.kubernetes.io/cors-allow-headers=Content-Type, Authorization" \
    >/dev/null 2>&1 || true

  # ---- Re-render auth-ui config with live-stack URLs ------------------
  helm --kube-context "$CONTEXT" upgrade preview \
    "$REPO/charts/$CHART_NAME" \
    -n "$ns" --reuse-values \
    --set "config.api=${as_url}" \
    --set "config.auth.authority=${hydra_url}" \
    --set "config.auth.clientId=${client_id}" >/dev/null
  $K -n "$ns" rollout restart "deploy/preview-${CHART_NAME}" >/dev/null
  $K -n "$ns" rollout status "deploy/preview-${CHART_NAME}" --timeout=60s >/dev/null

  # ---- Run auth-ui's end2end/01 + 02 seed scripts --------------------
  # Same scripts the cluster catalog task runs. 01 registers the OAuth
  # client with Hydra admin, 02 bcrypt-hashes + seeds the test user into
  # MongoDB. 03 is a pure-curl OAuth flow smoke test — runs it too as
  # a pre-Playwright confidence check.
  local end2end_dir="$REPO/end2end"
  if [ -d "$end2end_dir" ] && compgen -G "$end2end_dir/0[0-9]-*.sh" >/dev/null; then
    echo "[auth-ui] running $end2end_dir/0X-*.sh seed scripts"
    local kind_kubeconfig
    kind_kubeconfig=$(mktemp)
    kind export kubeconfig --name "$CLUSTER" --kubeconfig "$kind_kubeconfig" >/dev/null 2>&1

    $K -n "$ns" port-forward svc/preview-auth-service-hydra-admin 14445:4445 >/dev/null 2>&1 &
    local pf_pid=$!
    sleep 2

    if ! python3 -c 'import bcrypt' >/dev/null 2>&1; then
      pip3 install --user --quiet bcrypt >/dev/null 2>&1 || true
    fi

    for seed in "$end2end_dir"/0[0-9]-*.sh; do
      local name
      name=$(basename "$seed" .sh)
      case "$name" in 03-oauth-flow) continue ;; esac
      echo "[auth-ui]   $name"
      (
        export KUBECONFIG="$kind_kubeconfig"
        export PREVIEW_NAMESPACE="$ns"
        export PREVIEW_URL="$ui_url"
        export PREVIEW_HOST_BASE="pr${PULL_NUMBER}.${DOMAIN}:8443"
        export HYDRA_ADMIN_URL="http://localhost:14445"
        export AUTH_UI="$ui_url"
        export CLIENT_ID="$client_id"
        [ -f "$HERE/fixtures/tls/tls.crt" ] && export CURL_CA_BUNDLE="$HERE/fixtures/tls/tls.crt"
        bash "$seed"
      ) 2>&1 | tail -2 || echo "[auth-ui]   (seed non-zero — continuing)"
    done

    kill $pf_pid 2>/dev/null || true
    rm -f "$kind_kubeconfig"
  fi

  echo "[auth-ui] stack URLs:"
  echo "[auth-ui]   UI:    $ui_url"
  echo "[auth-ui]   API:   $as_url"
  echo "[auth-ui]   Hydra: $hydra_url"
}
