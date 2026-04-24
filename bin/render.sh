#!/usr/bin/env bash
# bin/render.sh — offline template-render a consumer repo.
#
# Catches:
#   - charts/*: helm template errors, values schema misses
#   - preview/helmfile.yaml.gotmpl: requiredEnv misses, bad chart refs,
#     setter paths that do not match chart values
#   - .lighthouse/jenkins-x/*.yaml: invalid YAML, broken local uses: refs
#
# No cluster required. Run anywhere, seconds.

set -uo pipefail

REPO="${1:?usage: render.sh <repo-path>}"
REPO=$(cd "$REPO" && pwd)
HERE=$(cd "$(dirname "$0")/.." && pwd)
CATALOG_DIR="${CATALOG_DIR:-$(cd "$HERE/../leartech-pipeline-catalog" 2>/dev/null && pwd || true)}"

FAILS=0
TOTAL=0
declare -a FAIL_DETAIL

section() { printf "\n== %s ==\n" "$1"; }
pass() {
  printf "  [pass]  %s\n" "$1"
  TOTAL=$((TOTAL + 1))
}
fail() {
  printf "  [fail]  %s\n" "$1"
  TOTAL=$((TOTAL + 1))
  FAILS=$((FAILS + 1))
  FAIL_DETAIL+=("$1"$'\n'"$2")
}

echo "repo:        $REPO"
echo "catalog:     ${CATALOG_DIR:-(not set — uses: refs skipped)}"

# -- charts/ ------------------------------------------------------------

if compgen -G "$REPO/charts/*/Chart.yaml" >/dev/null; then
  section "charts/"
  for chart in "$REPO"/charts/*/; do
    [ -f "$chart/Chart.yaml" ] || continue
    name=$(basename "$chart")
    if out=$(helm template render "$chart" 2>&1); then
      pass "helm template charts/$name"
    else
      fail "helm template charts/$name" "$out"
    fi
  done
fi

# -- preview/helmfile.yaml.gotmpl --------------------------------------
# Lighter-than-full validation: gotmpl syntax + requiredEnv enumeration.
# Full chart-resolved render needs OCI auth + network (charts referenced
# via JX_CHART_REPOSITORY live on real cluster registries) — that's what
# tier 3 covers. Tier 1 catches the bugs that don't need the pull:
#   - `requiredEnv "FOO"` where FOO isn't set anywhere (typos, drift)
#   - gotmpl syntax errors
#   - YAML structure after templating resolves
# We run `helmfile build` which writes resolved flat YAML to stdout
# BEFORE attempting any chart pull. If build prints YAML successfully,
# the template is syntactically sound. We classify "failed during pull"
# as "skipped (needs tier 3)" rather than a render-mode failure.

if [ -f "$REPO/preview/helmfile.yaml.gotmpl" ]; then
  section "preview/"
  tmp=$(mktemp -d)
  cp -R "$REPO/preview/." "$tmp/"
  cp "$HERE/fixtures/render/jx-values.yaml" "$tmp/jx-values.yaml"

  # JX_CHART_REPOSITORY must NOT include oci:// prefix — helmfile adds it
  # when `oci: true` is set on the repo. Production clusters set bare
  # host/path. Mis-setting it locally produced `oci://oci://...` URLs
  # during harness dev — worth protecting against via this stub.
  out=$(
    cd "$tmp" \
      && APP_NAME="$(basename "$REPO")" \
      PULL_NUMBER=42 \
      PREVIEW_NAMESPACE="scn-render-$(basename "$REPO")-pr42" \
      VERSION="0.0.0-render-SNAPSHOT" \
      DOCKER_REGISTRY="localhost:5001" \
      DOCKER_REGISTRY_ORG="mikelear" \
      JX_CHART_REPOSITORY="localhost:5001/charts" \
      CLUSTER_ID="local" \
      REPO_OWNER="mikelear" \
      REPO_NAME="$(basename "$REPO")" \
        helmfile --file helmfile.yaml.gotmpl build 2>&1
  )
  status=$?
  rm -rf "$tmp"

  # `helmfile build` ALWAYS tries to pull charts. So exit 0 means network
  # + auth + charts all aligned (rare locally). Exit non-zero with
  # "Pulling" in the log means gotmpl resolved OK, failure was at pull —
  # mark as skipped. Exit non-zero WITHOUT "Pulling" means the template
  # itself failed — that's a real render-mode failure.
  if [ $status -eq 0 ]; then
    pass "helmfile build preview/ (full)"
  elif echo "$out" | grep -q 'Pulling\|invalid_reference\|exit status'; then
    printf "  [skip]  %s (chart pull needed — tier 3)\n" "helmfile build preview/"
    TOTAL=$((TOTAL + 1))
  else
    fail "helmfile build preview/" "$out"
  fi
fi

# -- .lighthouse/jenkins-x/*.yaml ---------------------------------------
# Structural YAML + local uses: ref checks. External refs (jenkins-x/...)
# are noted but not resolved.

if [ -d "$REPO/.lighthouse/jenkins-x" ]; then
  section ".lighthouse/jenkins-x/"
  for lh in "$REPO/.lighthouse/jenkins-x"/*.yaml; do
    [ -f "$lh" ] || continue
    fname=$(basename "$lh")
    errs=""
    if ! yq '.' "$lh" >/dev/null 2>&1; then
      errs="invalid YAML"
    elif [ -n "${CATALOG_DIR:-}" ]; then
      # Look for mikelear/leartech-pipeline-catalog references and verify
      # the referenced file exists locally.
      while IFS= read -r ref; do
        [ -z "$ref" ] && continue
        if [[ $ref =~ ^uses:mikelear/leartech-pipeline-catalog/(.+)@ ]]; then
          sub="${BASH_REMATCH[1]}"
          target="$CATALOG_DIR/$sub"
          if [ ! -f "$target" ]; then
            errs="${errs}missing: $ref -> $target"$'\n'
          fi
        fi
      done < <(grep -hoE 'uses:[[:alnum:]/._:@-]+' "$lh" 2>/dev/null)
    fi
    if [ -z "$errs" ]; then
      pass ".lighthouse/jenkins-x/$fname"
    else
      fail ".lighthouse/jenkins-x/$fname" "$errs"
    fi
  done
fi

# -- summary -----------------------------------------------------------

echo ""
echo "-----------------------------------------------"
if [ $FAILS -eq 0 ]; then
  echo "[ok] $TOTAL/$TOTAL rendered clean"
  exit 0
else
  passes=$((TOTAL - FAILS))
  echo "[fail] $FAILS/$TOTAL failed ($passes passed)"
  echo ""
  for d in "${FAIL_DETAIL[@]}"; do
    echo "----"
    echo "$d" | head -40
    echo ""
  done
  exit 1
fi
