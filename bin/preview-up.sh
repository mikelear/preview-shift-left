#!/usr/bin/env bash
# bin/preview-up.sh — tier 3 preview for a consumer repo.
#
# Default path: applies the consumer's own preview/helmfile.yaml.gotmpl
# using `helmfile sync`. Same helmfile the cluster's catalog end2end task
# runs via `jx preview create`. Most repos' previews will work out of the
# box — jx-verify + local chart + whatever else they declare.
#
# Exception path: a consumer repo whose preview helmfile references deps
# that can't resolve on the local cluster (arm64-only images, OCI charts
# needing auth, etc.) can ship a substitutions file at
#   preview-shift-left/fixtures/local-substitutions/<repo-name>/setup.sh
# declaring PSL_SELECTOR (helmfile releases to skip) and psl_pre/psl_post
# hooks. leartech-auth-ui has one because bitnami mongo is amd64-only
# and the Hydra subchart's automigration init container fails on arm64.
#
# Usage:
#   bin/preview-up.sh <repo-path> [<chart-name>]
# Env:
#   PULL_NUMBER (default 42)    — simulated PR number
#   REPO_OWNER  (default mikelear)
#   DOMAIN      (default localtest.me)
#   WITH_TLS=1                  — force HTTPS ingress even without substitutions
#                                (substitutions can also set PSL_PROTO=https)

set -euo pipefail

REPO="${1:?usage: preview-up.sh <repo-path> [<chart-name>]}"
REPO=$(cd "$REPO" && pwd)
CHART_NAME="${2:-$(basename "$REPO")}"
CLUSTER="${CLUSTER:-preview-shift-left}"
CONTEXT="kind-${CLUSTER}"
PULL_NUMBER="${PULL_NUMBER:-42}"
REPO_OWNER="${REPO_OWNER:-mikelear}"
DOMAIN="${DOMAIN:-localtest.me}"

# Env leak guard — user shells may have KIND_EXPERIMENTAL_PROVIDER=podman
# from a previous session; the kind CLI would then try podman and fail.
unset KIND_EXPERIMENTAL_PROVIDER

HERE=$(cd "$(dirname "$0")/.." && pwd)
K="kubectl --context ${CONTEXT}"
export K CONTEXT CLUSTER PULL_NUMBER REPO_OWNER DOMAIN HERE REPO CHART_NAME

app_name=$(basename "$REPO")
ns="jx-${REPO_OWNER}-${app_name}-pr-${PULL_NUMBER}"
host="${app_name}-pr${PULL_NUMBER}.${DOMAIN}"

# ---- load consumer substitutions (if any) ----------------------------

overrides_dir="$HERE/fixtures/local-substitutions/$app_name"
PSL_SELECTOR=""
PSL_PROTO="http"
if [ -f "$overrides_dir/setup.sh" ]; then
  echo "[overrides] sourcing $overrides_dir/setup.sh"
  # shellcheck source=/dev/null
  source "$overrides_dir/setup.sh"
fi

# Protocol: substitutions can demand https (auth-ui: PKCE needs secure
# context). WITH_TLS=1 also forces https for repos that don't ship a
# substitutions file.
if [ "${WITH_TLS:-0}" = "1" ] || [ "$PSL_PROTO" = "https" ]; then
  proto="https"
  port="8443"
else
  proto="http"
  port="8080"
fi

echo "[repo]   $REPO"
echo "[chart]  $CHART_NAME"
echo "[ns]     $ns"
echo "[host]   $host"
echo "[proto]  $proto"

# ---- build + load consumer image -------------------------------------
# Thin `nginx:alpine` path: if the consumer has a pre-built `dist/` + nginx
# config, pack those into a multi-arch-compatible image. Otherwise use
# their real Dockerfile (which must build on the local arch).

img="localhost:5001/$app_name:local"
build_dir=$(mktemp -d)
if [ -d "$REPO/dist" ] && [ -f "$REPO/nginx/default.conf" ]; then
  echo "[build]  thin nginx image from $REPO/dist/"
  cp "$REPO/nginx/default.conf" "$build_dir/default.conf"
  cp -R "$REPO/dist" "$build_dir/dist"
  cat > "$build_dir/Dockerfile" <<'EOF'
FROM nginx:alpine
COPY default.conf /etc/nginx/conf.d/default.conf
COPY dist /tmp/dist
RUN set -e; \
  src=$(find /tmp/dist -type d -name browser | head -1); \
  test -n "$src" || { echo "no dist/*/browser found"; exit 1; }; \
  rm -rf /usr/share/nginx/html/*; \
  cp -R "$src"/* /usr/share/nginx/html/; \
  rm -rf /tmp/dist
EXPOSE 8080
EOF
elif [ -f "$REPO/Dockerfile" ]; then
  echo "[build]  real Dockerfile from $REPO/"
  build_dir="$REPO"
else
  echo "error: no Dockerfile nor dist/ found in $REPO"
  exit 1
fi
(cd "$build_dir" && docker build -t "$img" . 2>&1 | tail -2)
# Also tag as the image name the consumer helmfile's chart default expects.
docker tag "$img" "localhost:5001/${REPO_OWNER}/${app_name}:local-0.0.0" 2>/dev/null || true
docker push "localhost:5001/${REPO_OWNER}/${app_name}:local-0.0.0" >/dev/null 2>&1 || true
kind load docker-image --name "$CLUSTER" "$img" 2>&1 | tail -1

# ---- namespace + TLS secret ------------------------------------------

$K get ns "$ns" >/dev/null 2>&1 || $K create ns "$ns" >/dev/null

if [ "$proto" = "https" ]; then
  cert_dir="$HERE/fixtures/tls"
  mkdir -p "$cert_dir"
  if [ ! -f "$cert_dir/tls.crt" ]; then
    echo "[tls]    generating wildcard cert for *.${DOMAIN}"
    openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
      -subj "/CN=*.${DOMAIN}/O=preview-shift-left" \
      -addext "subjectAltName=DNS:*.${DOMAIN},DNS:${DOMAIN}" \
      -keyout "$cert_dir/tls.key" -out "$cert_dir/tls.crt" >/dev/null 2>&1
  fi
  $K -n "$ns" create secret tls wildcard-localtest \
    --cert="$cert_dir/tls.crt" --key="$cert_dir/tls.key" \
    --dry-run=client -o yaml | $K apply -f - >/dev/null
fi

# ---- pre-apply hook (from substitutions) -----------------------------

ui_url="${proto}://${host}:${port}"
if type -t psl_pre >/dev/null; then
  psl_pre "$ns" "$ui_url"
fi

# ---- apply consumer helmfile -----------------------------------------
# Mirror the repo structure into a tmp dir so the helmfile's relative
# paths (e.g. ../charts/leartech-auth-ui) resolve. The charts/ dir is
# symlinked (no copy) so live chart edits are picked up.

if [ -f "$REPO/preview/helmfile.yaml.gotmpl" ]; then
  echo "[helmfile] applying $REPO/preview/helmfile.yaml.gotmpl"
  tmp_preview=$(mktemp -d)
  cp -R "$REPO/preview" "$tmp_preview/preview"
  [ -d "$REPO/charts" ] && ln -s "$REPO/charts" "$tmp_preview/charts"
  # Replace the stub jx-values.yaml with ours (sets domain etc.).
  cp "$HERE/fixtures/preview-helmfile/jx-values-local.yaml" "$tmp_preview/preview/jx-values.yaml"

  selector_arg=""
  [ -n "$PSL_SELECTOR" ] && selector_arg="--selector $PSL_SELECTOR"

  # shellcheck disable=SC2097,SC2098  # Assignments are env prefixes for the subshell command on last line.
  (cd "$tmp_preview/preview" && \
    APP_NAME="$app_name" \
    PULL_NUMBER="$PULL_NUMBER" \
    REPO_OWNER="$REPO_OWNER" \
    REPO_NAME="$app_name" \
    PREVIEW_NAMESPACE="$ns" \
    VERSION="local-0.0.0" \
    JX_CHART_REPOSITORY="localhost:5001/charts" \
    DOCKER_REGISTRY="localhost:5001" \
    DOCKER_REGISTRY_ORG="$REPO_OWNER" \
    CLUSTER_ID="local" \
    helmfile --kube-context "$CONTEXT" --file helmfile.yaml.gotmpl $selector_arg sync 2>&1 | tail -15)
else
  # Fallback: consumer has no preview/helmfile — just install their chart.
  echo "[helm]   no preview/helmfile; installing charts/$CHART_NAME directly"
  helm --kube-context "$CONTEXT" upgrade --install preview "$REPO/charts/$CHART_NAME" \
    -n "$ns" \
    --set image.repository="localhost:5001/${app_name}" \
    --set image.tag="local" \
    --set image.pullPolicy="Never" \
    --set "jxRequirements.ingress.domain=${DOMAIN}" \
    --set "jxRequirements.ingress.namespaceSubDomain=-pr${PULL_NUMBER}." \
    --set jxRequirements.ingress.serviceType="ClusterIP" >/dev/null
fi

# ---- patch the consumer's own ingress for ingressClassName + TLS -----

$K -n "$ns" patch ingress "$CHART_NAME" --type=merge \
  -p '{"spec":{"ingressClassName":"nginx"}}' 2>/dev/null || true
if [ "$proto" = "https" ]; then
  $K -n "$ns" patch ingress "$CHART_NAME" --type=merge -p "$(cat <<JSON
{"spec":{"tls":[{"hosts":["$host"],"secretName":"wildcard-localtest"}]}}
JSON
)" 2>/dev/null || true
fi

# ---- post-apply hook (from substitutions) ----------------------------

if type -t psl_post >/dev/null; then
  psl_post "$ns" "$ui_url"
fi

# ---- sanity check + URL summary --------------------------------------

echo ""
echo "[host]   $host"
echo "[url]    $ui_url"

echo ""
echo "quick sanity via kind-host port mapping:"
ok=0
curl_k=""
[ "$proto" = "https" ] && curl_k="-k"
for i in 1 2 3 4 5 6 7 8; do
  if curl $curl_k -sfI -H "Host: $host" "${proto}://localhost:${port}/" 2>/dev/null | grep -qE 'HTTP/[12](\.[01])? 200'; then
    ok=1
    break
  fi
  sleep 2
done
if [ "$ok" = "1" ]; then
  echo "  200 OK (after ${i} attempt(s))"
  echo ""
  echo "[ok] preview up"
else
  echo "  FAILED after 16s"
  echo "  kubectl --context $CONTEXT -n $ns get pods,ingress"
  exit 1
fi
