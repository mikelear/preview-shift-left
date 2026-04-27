#!/usr/bin/env bash
# bin/analyze-repo.sh — static-inspect a consumer repo for Tier 3 blockers.
#
# Predicts what will fail in `make preview REPO=<repo>` BEFORE running it.
# Output: human-readable report + draft fixtures/local-substitutions/<name>/setup.sh.
#
# Detects the four blocker classes we hit on mqube-calculation-service:
#   1. Private chart deps in preview/helmfile.yaml.gotmpl
#   2. Deployment secretKeyRef / envFrom.secretRef → undefined Secret
#   3. Deployment volumes → undefined ConfigMap / Secret
#   4. Private images on initContainers / containers / sidecars
#
# Plus: helmfile presync hooks (jx secret copy etc.), Dockerfile private
# bases, build-time secrets (GIT_TOKEN ARGs), ExternalSecret CRDs.
#
# For accurate naming, renders via helmfile with --selector to skip the
# private deps (matching what preview-up.sh would actually deploy).
#
# Usage:
#   bin/analyze-repo.sh <repo-path>
#   bin/analyze-repo.sh <repo-path> --skeleton    # also write setup.sh draft

set -uo pipefail

REPO="${1:?usage: analyze-repo.sh <repo-path> [--skeleton]}"
REPO=$(cd "$REPO" && pwd)
WRITE_SKELETON=0
[ "${2:-}" = "--skeleton" ] && WRITE_SKELETON=1

HERE=$(cd "$(dirname "$0")/.." && pwd)
APP_NAME=$(basename "$REPO")
CHART_DIR="$REPO/charts/$APP_NAME"

PUBLIC_REGISTRY_RE='(^|/)(mcr\.microsoft\.com|gcr\.io|ghcr\.io|quay\.io|docker\.io|registry-1\.docker\.io|public\.ecr\.aws|registry\.k8s\.io|localhost:5001|registry\.access\.redhat\.com|nvcr\.io)/'
PUBLIC_HELM_RE='(jenkins-x-charts\.github\.io|charts\.jenkins-x\.io|charts\.bitnami\.com|raw\.githubusercontent\.com|stefanprodan\.github\.io|kubernetes\.github\.io|grafana\.github\.io|prometheus-community\.github\.io|ory\.github\.io|localhost:5001)'

is_public_image() {
  local img="$1"
  if [[ "$img" != */* ]] || [[ "$img" =~ ^[^./]+:[^/]+$ && "$img" != *.*/* ]]; then
    return 0
  fi
  [[ "$img" =~ $PUBLIC_REGISTRY_RE ]]
}

is_public_helm_repo() {
  [[ "$1" =~ $PUBLIC_HELM_RE ]]
}

# Render the chart the same way preview-up.sh would, with helmfile +
# selector to skip private deps. Falls back to bare `helm template` if
# the repo has no preview helmfile or rendering fails.
#
# Args: $1 = local release name to keep (others skipped via selector)
# Output: JSON array of rendered K8s docs on stdout, or "[]" on failure.
render_docs() {
  local local_release="${1:-preview}"
  local helmfile="$REPO/preview/helmfile.yaml.gotmpl"
  local rendered

  if [ -f "$helmfile" ]; then
    local tmp
    tmp=$(mktemp -d)
    cp -R "$REPO/preview" "$tmp/preview"
    [ -d "$REPO/charts" ] && ln -s "$REPO/charts" "$tmp/charts"
    cp "$HERE/fixtures/preview-helmfile/jx-values-local.yaml" "$tmp/preview/jx-values.yaml" 2>/dev/null || true

    rendered=$(cd "$tmp/preview" && \
      APP_NAME="$APP_NAME" \
      PULL_NUMBER="42" \
      REPO_OWNER="${REPO_OWNER:-spring-financial-group}" \
      REPO_NAME="$APP_NAME" \
      VERSION="local-0.0.0" \
      PREVIEW_NAMESPACE="analyze-stub" \
      DOCKER_REGISTRY="localhost:5001" \
      DOCKER_REGISTRY_ORG="${REPO_OWNER:-spring-financial-group}" \
      CLUSTER_ID="local" \
      helmfile --file helmfile.yaml.gotmpl --selector "name=$local_release" template 2>/dev/null)
    rm -rf "$tmp"
  fi

  if [ -z "$rendered" ] && [ -d "$CHART_DIR" ]; then
    rendered=$(helm template "$CHART_DIR" 2>/dev/null)
  fi

  if [ -z "$rendered" ]; then
    echo "[]"
    return
  fi

  echo "$rendered" | yq -o=json eval-all '.' 2>/dev/null | jq -s '. | map(select(. != null and (type == "object")))' 2>/dev/null || echo "[]"
}

# Parse the preview helmfile (which may have multiple YAML docs) into a
# JSON array; we then query whichever doc has the field we want.
parse_helmfile() {
  local f="$1"
  yq -o=json eval-all '.' "$f" 2>/dev/null | jq -s '.' 2>/dev/null
}

echo "================================================================"
echo "  analyze-repo: $APP_NAME"
echo "  path:         $REPO"
echo "================================================================"

# ---- 1. Dockerfile ---------------------------------------------------

echo ""
echo "[1/5] Dockerfile"
if [ -f "$REPO/Dockerfile" ]; then
  while IFS= read -r line; do
    base="${line#FROM }"
    base="${base%% AS *}"
    base="${base%% as *}"
    base=$(echo "$base" | tr -d '[:space:]')
    [ -z "$base" ] && continue
    if is_public_image "$base"; then
      echo "  ✓ FROM $base"
    else
      echo "  ✗ FROM $base   (private — needs az/docker login or local mirror)"
    fi
  done < <(grep -E '^FROM ' "$REPO/Dockerfile")

  if grep -qE 'GIT_TOKEN|NPM_TOKEN|NUGET_PASSWORD|--mount=type=secret' "$REPO/Dockerfile"; then
    echo "  ⚠ build-time secrets referenced (GIT_TOKEN / NPM_TOKEN / mount=secret)"
  fi
else
  echo "  (no Dockerfile)"
fi

# ---- 2. Preview helmfile --------------------------------------------

echo ""
echo "[2/5] Preview helmfile"
HELMFILE="$REPO/preview/helmfile.yaml.gotmpl"
PRIVATE_RELEASES=()
LOCAL_RELEASE=""
if [ -f "$HELMFILE" ]; then
  HF_JSON=$(parse_helmfile "$HELMFILE")
  if [ -z "$HF_JSON" ] || [ "$HF_JSON" = "null" ] || [ "$HF_JSON" = "[]" ]; then
    echo "  (can't statically parse — gotmpl too complex; chart-render section still runs)"
    LOCAL_RELEASE="preview"
    HF_JSON='[]'
  fi

  echo "$HF_JSON" | jq -r '.[] | select(.repositories) | .repositories[] | .url // ""' | while IFS= read -r url; do
    [ -z "$url" ] && continue
    if is_public_helm_repo "$url" || [[ "$url" == "localhost:"* ]]; then
      :
    else
      echo "  ✗ private repo: $url"
    fi
  done

  # Map repo alias → URL, so chart "jx3/jx-verify" can be resolved against
  # the repositories[] table to know if the underlying registry is public.
  REPO_URLS=$(echo "$HF_JSON" | jq -c '[.[] | select(.repositories) | .repositories[]?] | map({(.name): .url}) | add // {}')

  while IFS=$'\t' read -r name chart; do
    [ -z "$name" ] && continue
    if [[ "$chart" == ../* || "$chart" == ./* ]]; then
      echo "  ✓ release: $name → $chart   (local chart)"
      LOCAL_RELEASE="$name"
    else
      repo_alias="${chart%%/*}"
      repo_url=$(echo "$REPO_URLS" | jq -r --arg n "$repo_alias" '.[$n] // ""')
      if [ -n "$repo_url" ] && (is_public_helm_repo "$repo_url" || [[ "$repo_url" == "localhost:"* ]]); then
        echo "  ✓ release: $name → $chart   (public: $repo_url)"
      else
        echo "  ✗ release: $name → $chart   (private dep — would 401)"
        PRIVATE_RELEASES+=("$name")
      fi
    fi
  done < <(echo "$HF_JSON" | jq -r '.[] | select(.releases) | .releases[] | [.name, .chart] | @tsv')

  hook_cmds=$(echo "$HF_JSON" | jq -r '.[] | select(.releases) | .releases[]?.hooks[]?.command // empty' | grep -v '^$' | sort -u | tr '\n' ',' | sed 's/,$//')
  if [ -n "$hook_cmds" ]; then
    echo "  ⚠ helmfile hooks call: $hook_cmds   (likely needs cluster-side tooling)"
  fi
else
  echo "  (no preview/helmfile.yaml.gotmpl — fallback path will install $CHART_DIR directly)"
  LOCAL_RELEASE="preview"
fi

# ---- 3. Chart-rendered analysis -------------------------------------

echo ""
echo "[3/5] Chart-rendered analysis"
if [ ! -d "$CHART_DIR" ]; then
  echo "  (no charts/$APP_NAME — skipping)"
  exit 0
fi

DOCS_JSON=$(render_docs "${LOCAL_RELEASE:-preview}")
doc_count=$(echo "$DOCS_JSON" | jq 'length')
if [ "$doc_count" = "0" ]; then
  echo "  (rendering failed — no chart docs to inspect)"
  exit 0
fi
echo "  rendered $doc_count manifest(s) via $([ -f "$HELMFILE" ] && echo "helmfile (selector=name=$LOCAL_RELEASE)" || echo "helm template")"

DEFINED_SECRETS=$(echo "$DOCS_JSON" | jq -r '.[] | select(.kind=="Secret") | .metadata.name' | sort -u)
DEFINED_CMS=$(echo "$DOCS_JSON" | jq -r '.[] | select(.kind=="ConfigMap") | .metadata.name' | sort -u)

REFERENCED_SECRETS=$(echo "$DOCS_JSON" | jq -r '
  .. | objects |
    (.secretKeyRef?.name,
     .secretRef?.name,
     .secret?.secretName,
     .imagePullSecrets?[]?.name)
' | grep -v '^null$' | grep -v '^$' | sort -u)

REFERENCED_CMS=$(echo "$DOCS_JSON" | jq -r '
  .. | objects |
    (.configMapKeyRef?.name,
     .configMapRef?.name,
     .configMap?.name)
' | grep -v '^null$' | grep -v '^$' | sort -u)

MISSING_SECRETS=$(comm -23 <(echo "$REFERENCED_SECRETS") <(echo "$DEFINED_SECRETS"))
MISSING_CMS=$(comm -23 <(echo "$REFERENCED_CMS") <(echo "$DEFINED_CMS"))

secret_keys() {
  echo "$DOCS_JSON" | jq -r --arg n "$1" '
    .. | objects | select(.secretKeyRef?.name == $n) | .secretKeyRef.key
  ' | grep -v '^null$' | grep -v '^$' | sort -u | tr '\n' ',' | sed 's/,$//'
}

cm_keys() {
  local kr_keys vol_keys
  kr_keys=$(echo "$DOCS_JSON" | jq -r --arg n "$1" '
    .. | objects | select(.configMapKeyRef?.name == $n) | .configMapKeyRef.key
  ' | grep -v '^null$' | grep -v '^$')
  vol_keys=$(echo "$DOCS_JSON" | jq -r --arg n "$1" '
    .. | objects | select(.configMap?.name == $n) | .configMap.items?[]?.key
  ' | grep -v '^null$' | grep -v '^$')
  printf '%s\n%s\n' "$kr_keys" "$vol_keys" | grep -v '^$' | sort -u | tr '\n' ',' | sed 's/,$//'
}

if [ -n "$MISSING_SECRETS" ]; then
  echo "  ✗ Secrets referenced but not defined in chart (need psl_pre stubs):"
  while IFS= read -r s; do
    [ -z "$s" ] && continue
    keys=$(secret_keys "$s")
    [ -z "$keys" ] && keys="(envFrom — keys unknown)"
    echo "      $s   keys=$keys"
  done <<< "$MISSING_SECRETS"
fi

if [ -n "$MISSING_CMS" ]; then
  echo "  ✗ ConfigMaps referenced but not defined in chart (need psl_pre stubs):"
  while IFS= read -r c; do
    [ -z "$c" ] && continue
    keys=$(cm_keys "$c")
    [ -z "$keys" ] && keys="(whole-CM volume mount — common key: config.yaml)"
    echo "      $c   keys=$keys"
  done <<< "$MISSING_CMS"
fi

# ---- 4. Container images --------------------------------------------

echo ""
echo "[4/5] Container images"
images=$(echo "$DOCS_JSON" | jq -r '
  .[] | (
    .spec?.template?.spec?.containers?[]?.image,
    .spec?.template?.spec?.initContainers?[]?.image,
    .spec?.containers?[]?.image
  )
' | grep -v '^null$' | grep -v '^$' | sort -u)

PRIVATE_IMAGES=()
while IFS= read -r img; do
  [ -z "$img" ] && continue
  # Strip surrounding quotes if any (yq sometimes emits quoted strings).
  img="${img%\"}"; img="${img#\"}"
  if [[ "$img" == "draft:dev" || "$img" == "draft:latest" ]] \
      || [[ "$img" == "localhost:5001/"* ]]; then
    echo "  ✓ $img   (consumer's own — built locally)"
  elif is_public_image "$img"; then
    echo "  ✓ $img"
  else
    echo "  ✗ $img   (private — patch deployment to public stub OR mirror)"
    PRIVATE_IMAGES+=("$img")
  fi
done <<< "$images"

es_count=$(echo "$DOCS_JSON" | jq '[.[] | select(.kind=="ExternalSecret")] | length')
if [ "$es_count" -gt 0 ]; then
  echo ""
  echo "  ⚠ ExternalSecret CRDs in chart ($es_count) — won't reconcile on kind"
  echo "$DOCS_JSON" | jq -r '.[] | select(.kind=="ExternalSecret") | "      " + .metadata.name'
fi

# ---- 5. Skeleton -----------------------------------------------------

echo ""
echo "[5/5] Suggested fixtures/local-substitutions/$APP_NAME/setup.sh"
echo ""

skeleton="#!/usr/bin/env bash
# Tier 3 substitutions for $APP_NAME — generated by bin/analyze-repo.sh.
# Review every line; the analyzer is best-effort, not authoritative.
"

if [ "${#PRIVATE_RELEASES[@]}" -gt 0 ] && [ -n "$LOCAL_RELEASE" ]; then
  skeleton+="
# Skip private OCI chart dep(s); sync only the consumer's own release.
PSL_SELECTOR=\"name=$LOCAL_RELEASE\"
"
fi

skeleton+="
psl_pre() {
  local ns=\"\$1\"
"

while IFS= read -r s; do
  [ -z "$s" ] && continue
  keys=$(secret_keys "$s")
  if [ -z "$keys" ]; then
    skeleton+="  \$K -n \"\$ns\" create secret generic $s --from-literal=placeholder=stub --dry-run=client -o yaml | \$K apply -f - >/dev/null
"
  else
    args=""
    IFS=',' read -ra arr <<< "$keys"
    for k in "${arr[@]}"; do
      args+=" --from-literal=$k=stub"
    done
    skeleton+="  \$K -n \"\$ns\" create secret generic $s$args --dry-run=client -o yaml | \$K apply -f - >/dev/null
"
  fi
done <<< "$MISSING_SECRETS"

while IFS= read -r c; do
  [ -z "$c" ] && continue
  keys=$(cm_keys "$c")
  args=""
  if [ -z "$keys" ]; then
    args=" --from-literal=config.yaml='# stub'"
  else
    IFS=',' read -ra arr <<< "$keys"
    for k in "${arr[@]}"; do
      args+=" --from-literal=$k='# stub'"
    done
  fi
  skeleton+="  \$K -n \"\$ns\" create configmap $c$args --dry-run=client -o yaml | \$K apply -f - >/dev/null
"
done <<< "$MISSING_CMS"

if [ "${#PRIVATE_IMAGES[@]}" -gt 0 ]; then
  skeleton+="
  # Private images detected — patch the deployment to use a public stub OR
  # mirror to localhost:5001 (\`az acr login && regctl image copy ...\`):
"
  for img in "${PRIVATE_IMAGES[@]}"; do
    skeleton+="  #   $img
"
  done
fi

skeleton+="}
"

echo "$skeleton"

if [ "$WRITE_SKELETON" = "1" ]; then
  out_dir="$HERE/fixtures/local-substitutions/$APP_NAME"
  mkdir -p "$out_dir"
  if [ -f "$out_dir/setup.sh" ]; then
    echo "[skip-write] $out_dir/setup.sh exists — skeleton not written. Diff manually if you want to merge."
  else
    echo "$skeleton" > "$out_dir/setup.sh"
    chmod +x "$out_dir/setup.sh"
    echo "[wrote] $out_dir/setup.sh"
  fi
fi
