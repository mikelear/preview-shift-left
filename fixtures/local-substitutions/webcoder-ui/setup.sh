# shellcheck shell=bash
# Local substitutions for webcoder-ui — Tier 3 full auth stack on kind.
#
# Mirrors leartech-auth-ui's substitution pattern, extended for the
# 6-release option-b helmfile webcoder-ui ships:
#
#   1. auth-postgresql        → runs from helmfile (bitnami-oci/postgresql
#                                is multi-arch — no arm64 issue. Same
#                                config as auth-service preview: single
#                                instance, two DBs hydra + auth_service,
#                                seeded via initdbScripts).
#   2. preview-auth-service   → skip OCI; helm install from local chart
#                                with memory-DSN Hydra subchart + Postgres
#                                store backend (matches real preview shape)
#   3. preview-auth-ui        → skip OCI; helm install from local chart,
#                                points at preview-auth-service URL/Hydra
#   4. preview-webcoder-service → skip OCI; helm install from local chart,
#                                shell-mode (no DB), auth.serverUrl=preview
#                                Hydra so it'd validate inbound JWTs
#   5. preview (webcoder-ui)  → runs from helmfile (image built by harness's
#                                thin-nginx flow); re-rendered post-deploy
#                                with live URLs
#   6. preview-gate           → runs from helmfile
#
# Why bother: the 5 webcoder-ui Playwright specs assert the full OIDC
# chain (AuthGuard → Hydra discovery → login form → callback → dashboard
# with id_token claims). Without the live stack they all fail. Local
# tier-3 cuts the iteration loop from ~15 min PR round-trip to ~2 min
# preview + ~6s/spec — essential as the dashboard adds more specs.
#
# Hook contract (see preview-up.sh):
#   PSL_SELECTOR — helmfile --selector value to filter releases
#   PSL_PROTO    — https / http for the consumer ingress
#   psl_pre()    — runs BEFORE helmfile sync (build images, package charts)
#   psl_post()   — runs AFTER  helmfile sync (substitute deploys, TLS, seeds)

# shellcheck disable=SC2034  # vars consumed by preview-up.sh after sourcing
PSL_SELECTOR='name!=preview-auth-service,name!=preview-auth-ui,name!=preview-webcoder-service'
# shellcheck disable=SC2034
PSL_PROTO="https"

# ----------------------------------------------------------------------
# psl_pre — package charts + build native arm64 images for the substitutes.
# ----------------------------------------------------------------------
psl_pre() {
  local ns="$1"
  local ui_url="$2"

  # ---- leartech-auth-service chart -----------------------------------
  echo "[webcoder-ui] packaging + pushing auth-service chart"
  local as_chart="${AUTH_SERVICE_REPO:-$HOME/leartech/leartech-auth-service}/charts/leartech-auth-service"
  (cd "$as_chart" && helm dep build . >/dev/null 2>&1)
  local pkg
  pkg=$(helm package "$as_chart" -d /tmp 2>/dev/null | awk -F': ' '{print $NF}')
  helm push "$pkg" oci://localhost:5001/charts >/dev/null 2>&1 || true

  # ---- leartech-auth-service binary + image (arm64 native) -----------
  echo "[webcoder-ui] building auth-service (arm64 native) and pushing"
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

  # ---- leartech-auth-ui chart ----------------------------------------
  echo "[webcoder-ui] packaging + pushing auth-ui chart"
  local au_chart="${AUTH_UI_REPO:-$HOME/leartech/leartech-auth-ui}/charts/leartech-auth-ui"
  (cd "$au_chart" && helm dep build . >/dev/null 2>&1)
  local au_pkg
  au_pkg=$(helm package "$au_chart" -d /tmp 2>/dev/null | awk -F': ' '{print $NF}')
  helm push "$au_pkg" oci://localhost:5001/charts >/dev/null 2>&1 || true

  # ---- leartech-auth-ui image (arm64 nginx, prebuilt Angular bundle) -
  # The leartech-nginx base is multi-arch so a native build works. We
  # just need the dist/ contents — assumes auth-ui has run `npm run build`
  # at least once. If not, do it now.
  echo "[webcoder-ui] building auth-ui image (arm64 nginx)"
  local au_repo="${AUTH_UI_REPO:-$HOME/leartech/leartech-auth-ui}"
  if [ ! -d "$au_repo/dist/leartech-auth-ui/browser" ]; then
    echo "[webcoder-ui]   auth-ui dist/ missing — running npm run build"
    (cd "$au_repo" && npm install --silent >/dev/null 2>&1 && npm run build >/dev/null 2>&1)
  fi
  local au_build_dir
  au_build_dir=$(mktemp -d)
  cp -r "$au_repo/dist/leartech-auth-ui/browser" "$au_build_dir/browser"
  if [ -f "$au_repo/nginx/default.conf" ]; then
    mkdir -p "$au_build_dir/nginx"
    cp "$au_repo/nginx/default.conf" "$au_build_dir/nginx/default.conf"
  fi
  cat >"$au_build_dir/Dockerfile" <<'EOF'
FROM ghcr.io/mikelear/leartech-nginx:0.19.0
COPY nginx/default.conf /etc/nginx/conf.d/default.conf
COPY browser /usr/share/nginx/html
USER 101
EXPOSE 8080
CMD ["nginx", "-g", "daemon off;"]
EOF
  (cd "$au_build_dir" && docker build -t localhost:5001/mikelear/leartech-auth-ui:latest .) >/dev/null 2>&1
  docker push localhost:5001/mikelear/leartech-auth-ui:latest >/dev/null 2>&1
  rm -rf "$au_build_dir"

  # ---- webcoder-service chart -----------------------------------------
  echo "[webcoder-ui] packaging + pushing webcoder-service chart"
  local bff_chart="${WEBCODER_SERVICE_REPO:-$HOME/leartech/webcoder-service}/charts/webcoder-service"
  (cd "$bff_chart" && helm dep build . >/dev/null 2>&1)
  local bff_pkg
  bff_pkg=$(helm package "$bff_chart" -d /tmp 2>/dev/null | awk -F': ' '{print $NF}')
  helm push "$bff_pkg" oci://localhost:5001/charts >/dev/null 2>&1 || true

  # ---- webcoder-service binary + image (arm64 native) -----------------
  echo "[webcoder-ui] building webcoder-service (arm64 native) and pushing"
  local bff_bin
  bff_bin=$(mktemp)
  (cd "${WEBCODER_SERVICE_REPO:-$HOME/leartech/webcoder-service}" \
    && GOOS=linux GOARCH=arm64 CGO_ENABLED=0 \
      go build -ldflags='-w -s' -o "$bff_bin" ./cmd/server) >/dev/null
  local bff_build_dir
  bff_build_dir=$(mktemp -d)
  mv "$bff_bin" "$bff_build_dir/webcoder-service"
  cat >"$bff_build_dir/Dockerfile" <<'EOF'
FROM alpine:3.19
RUN apk add --no-cache ca-certificates tzdata && adduser -D -u 1000 app
USER app
COPY webcoder-service /usr/local/bin/webcoder-service
EXPOSE 8080
ENTRYPOINT ["webcoder-service"]
EOF
  (cd "$bff_build_dir" && docker build -t localhost:5001/mikelear/webcoder-service:latest .) >/dev/null 2>&1
  docker push localhost:5001/mikelear/webcoder-service:latest >/dev/null 2>&1
  rm -rf "$bff_build_dir"

  # ---- jx stub on PATH (presync `jx secret copy` no-op) --------------
  $K create ns preview-secrets --dry-run=client -o yaml | $K apply -f - >/dev/null
  PSL_JX_STUB=$(mktemp -d)
  cat >"$PSL_JX_STUB/jx" <<'EOF'
#!/bin/sh
exit 0
EOF
  chmod +x "$PSL_JX_STUB/jx"
  export PATH="$PSL_JX_STUB:$PATH"
}

# ----------------------------------------------------------------------
# psl_post — substitute deploys, ingress fixes, OAuth/user seeds.
# ----------------------------------------------------------------------
psl_post() {
  local ns="$1"
  local ui_url="$2"
  local as_host="leartech-auth-service-pr${PULL_NUMBER}.${DOMAIN}"
  local au_host="leartech-auth-ui-pr${PULL_NUMBER}.${DOMAIN}"
  local hydra_host="hydra-pr${PULL_NUMBER}.${DOMAIN}"
  local bff_host="webcoder-service-pr${PULL_NUMBER}.${DOMAIN}"
  local as_url="https://${as_host}:8443"
  local au_url="https://${au_host}:8443"
  local hydra_url="https://${hydra_host}:8443"
  local bff_url="https://${bff_host}:8443"
  local client_id="${HYDRA_CLIENT_ID:-webcoder-ui}"

  # ---- Wait for helmfile-deployed Postgres to be ready ---------------
  # auth-postgresql runs as a normal helmfile release (bitnami-oci/
  # postgresql is multi-arch). Same shape as auth-service's own preview:
  # single instance, two databases (hydra + auth_service) created via
  # initdbScripts in webcoder-ui/preview/postgresql.yaml.
  echo "[webcoder-ui] waiting for auth-postgresql to be ready"
  $K -n "$ns" rollout status statefulset/auth-postgresql --timeout=180s >/dev/null

  # ---- Substitute for preview-auth-service (Hydra subchart, postgres) ----
  # Hydra uses memory DSN locally (bitnami-pg startup race with Hydra's
  # automigration init container has bitten before). Auth-service user
  # store IS Postgres (matches real preview shape).
  #
  # Pulls the consumer's own auth-service-values.yaml.gotmpl so a wrong
  # key in that file fails locally too — that's exactly how PR #5
  # initially hit MONGO_URI on CI when shift-left passed (storeBackend
  # vs store.backend silent typo, hidden by --set overrides). Only the
  # truly local-specific bits stay as --set overrides below.
  echo "[webcoder-ui] deploying preview-auth-service (local chart, postgres store)"
  local as_chart="${AUTH_SERVICE_REPO:-$HOME/leartech/leartech-auth-service}/charts/leartech-auth-service"
  local as_values_rendered
  as_values_rendered=$(mktemp)
  # Render the gotmpl tokens (only requiredEnv ones used in the file):
  sed \
    -e "s|{{ requiredEnv \"DOCKER_REGISTRY\" }}|localhost:5001|g" \
    -e "s|{{ requiredEnv \"DOCKER_REGISTRY_ORG\" }}|mikelear|g" \
    "$REPO/preview/auth-service-values.yaml.gotmpl" > "$as_values_rendered"
  helm --kube-context "$CONTEXT" upgrade --install preview-auth-service "$as_chart" \
    -n "$ns" \
    -f "$as_values_rendered" \
    --set image.repository=localhost:5001/mikelear/leartech-auth-service \
    --set image.tag=latest \
    --set image.pullPolicy=IfNotPresent \
    --set clusterID=local \
    --set "authUIURL=${au_url}" \
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
    --set "hydra.hydra.config.urls.login=${au_url}/login" \
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

  # ---- Substitute for preview-auth-ui (local chart) ------------------
  echo "[webcoder-ui] deploying preview-auth-ui (local chart, points at preview-auth-service)"
  local au_chart="${AUTH_UI_REPO:-$HOME/leartech/leartech-auth-ui}/charts/leartech-auth-ui"
  helm --kube-context "$CONTEXT" upgrade --install preview-auth-ui "$au_chart" \
    -n "$ns" \
    --set image.repository=localhost:5001/mikelear/leartech-auth-ui \
    --set image.tag=latest \
    --set image.pullPolicy=IfNotPresent \
    --set "jxRequirements.ingress.domain=${DOMAIN}" \
    --set "jxRequirements.ingress.namespaceSubDomain=-pr${PULL_NUMBER}." \
    --set "jxRequirements.ingress.serviceType=ClusterIP" \
    --set "config.api=${as_url}" \
    --set "config.auth.authority=${hydra_url}" \
    --set "config.auth.clientId=${client_id}" >/dev/null
  $K -n "$ns" rollout status deploy/preview-auth-ui-leartech-auth-ui --timeout=60s >/dev/null 2>&1 \
    || $K -n "$ns" rollout status deploy/preview-auth-ui --timeout=60s >/dev/null

  # ---- Substitute for preview-webcoder-service (BFF, shell-mode) -----
  echo "[webcoder-ui] deploying preview-webcoder-service (local chart, shell-mode)"
  local bff_chart="${WEBCODER_SERVICE_REPO:-$HOME/leartech/webcoder-service}/charts/webcoder-service"
  helm --kube-context "$CONTEXT" upgrade --install preview-webcoder-service "$bff_chart" \
    -n "$ns" \
    --set image.repository=localhost:5001/mikelear/webcoder-service \
    --set image.tag=latest \
    --set image.pullPolicy=IfNotPresent \
    --set "jxRequirements.ingress.domain=${DOMAIN}" \
    --set "jxRequirements.ingress.namespaceSubDomain=-pr${PULL_NUMBER}." \
    --set "jxRequirements.ingress.serviceType=ClusterIP" \
    --set database.enabled=false \
    --set migrations.enabled=false \
    --set oauth.createHydraOAuthClients=false \
    --set "auth.serverUrl=${hydra_url}" >/dev/null
  $K -n "$ns" rollout status deploy/preview-webcoder-service --timeout=60s >/dev/null

  # ---- TLS + CORS on ingresses we own --------------------------------
  for ing_host in \
    "leartech-auth-service:${as_host}" \
    "preview-auth-service-hydra-public:${hydra_host}" \
    "leartech-auth-ui:${au_host}" \
    "webcoder-service:${bff_host}"; do
    local ing="${ing_host%%:*}"
    local hp="${ing_host##*:}"
    $K -n "$ns" patch ingress "$ing" --type=merge -p "$(
      cat <<JSON
{"spec":{"ingressClassName":"nginx","tls":[{"hosts":["$hp"],"secretName":"wildcard-localtest"}]}}
JSON
    )" >/dev/null 2>&1 || true
  done
  # auth-service ingress accepts CORS from auth-ui (which posts the
  # login form); webcoder-ui never directly XHRs to auth-service.
  $K -n "$ns" annotate ingress leartech-auth-service --overwrite \
    nginx.ingress.kubernetes.io/enable-cors=true \
    "nginx.ingress.kubernetes.io/cors-allow-origin=${au_url}" \
    nginx.ingress.kubernetes.io/cors-allow-credentials=true \
    "nginx.ingress.kubernetes.io/cors-allow-methods=GET, POST, OPTIONS" \
    "nginx.ingress.kubernetes.io/cors-allow-headers=Content-Type, Authorization" \
    >/dev/null 2>&1 || true
  # webcoder-service ingress accepts CORS from webcoder-ui (the dashboard
  # XHRs into /api/v1/* with the bearer token from the OIDC flow).
  $K -n "$ns" annotate ingress webcoder-service --overwrite \
    nginx.ingress.kubernetes.io/enable-cors=true \
    "nginx.ingress.kubernetes.io/cors-allow-origin=${ui_url}" \
    nginx.ingress.kubernetes.io/cors-allow-credentials=true \
    "nginx.ingress.kubernetes.io/cors-allow-methods=GET, POST, PUT, DELETE, OPTIONS" \
    "nginx.ingress.kubernetes.io/cors-allow-headers=Content-Type, Authorization" \
    >/dev/null 2>&1 || true

  # ---- Re-render webcoder-ui (this PR's chart) with live URLs -------
  helm --kube-context "$CONTEXT" upgrade preview \
    "$REPO/charts/$CHART_NAME" \
    -n "$ns" --reuse-values \
    --set "config.api=${bff_url}" \
    --set "config.auth.authority=${hydra_url}" \
    --set "config.auth.clientId=${client_id}" >/dev/null
  $K -n "$ns" rollout restart "deploy/preview-${CHART_NAME}" >/dev/null
  $K -n "$ns" rollout status "deploy/preview-${CHART_NAME}" --timeout=60s >/dev/null

  # ---- Run end2end seed scripts (register OAuth + seed test user) ---
  local end2end_dir="$REPO/end2end"
  if [ -d "$end2end_dir" ] && compgen -G "$end2end_dir/0[0-9]-*.sh" >/dev/null; then
    echo "[webcoder-ui] running $end2end_dir/0X-*.sh seed scripts"
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
      # Skip the smoke + the OAuth flow check — preview-up.sh already
      # smoke-tests the URL, and the curl flow check belongs in tests
      # not setup. The seed scripts we DO run: 01-register-oauth-client
      # + 02-seed-test-user (which talks to the helmfile-deployed
      # Postgres natively — no local override needed since auth-service
      # is now Postgres-backed locally too).
      case "$name" in
        01-smoke | 03-oauth-flow) continue ;;
      esac
      echo "[webcoder-ui]   $name"
      (
        export KUBECONFIG="$kind_kubeconfig"
        export PREVIEW_NAMESPACE="$ns"
        export PREVIEW_URL="$ui_url"
        export PREVIEW_HOST_BASE="pr${PULL_NUMBER}.${DOMAIN}:8443"
        export HYDRA_ADMIN_URL="http://localhost:14445"
        export CLIENT_ID="$client_id"
        [ -f "$HERE/fixtures/tls/tls.crt" ] && export CURL_CA_BUNDLE="$HERE/fixtures/tls/tls.crt"
        bash "$seed"
      ) 2>&1 | tail -2 || echo "[webcoder-ui]   (seed non-zero — continuing)"
    done

    kill $pf_pid 2>/dev/null || true
    rm -f "$kind_kubeconfig"
  fi

  echo "[webcoder-ui] stack URLs:"
  echo "[webcoder-ui]   webcoder-ui:      $ui_url"
  echo "[webcoder-ui]   webcoder-service: $bff_url"
  echo "[webcoder-ui]   auth-ui (login):  $au_url"
  echo "[webcoder-ui]   auth-service:     $as_url"
  echo "[webcoder-ui]   Hydra:            $hydra_url"
}
