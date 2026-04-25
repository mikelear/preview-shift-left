#!/usr/bin/env bash
# bin/survey.sh — categorise an organisation-wide directory of repos for
# harness compatibility. Runs `make render`-equivalent on each, classifies:
#
#   ok                — has .lighthouse/, render succeeded, harness ready
#   chart-dep-auth    — render failed because helm dep download hit a 401
#                       on a private OCI registry. Real-world expected
#                       outside the cluster's network; an engineer
#                       authenticated to that registry would render fine.
#                       Not a framework bug.
#   template-error    — has .lighthouse/, render failed for chart/helmfile
#                       reasons that aren't auth — actual bug or
#                       missing config in the consumer repo.
#   no-pipelines      — no .lighthouse/jenkins-x/ — out of scope for harness
#   not-a-repo        — directory exists but isn't a git checkout (vendored
#                       charts, raw notes, etc.)
#
# Usage:
#   bin/survey.sh [SCAN_DIR]                 # default ~/mqubeRepos
#   bin/survey.sh ~/mqubeRepos --quiet       # silence per-repo output
#   bin/survey.sh ~/mqubeRepos > survey.txt  # capture full report
#
# Each render is bounded with a per-repo timeout to prevent hangs.

set -uo pipefail

SCAN_DIR="${1:-${HOME}/mqubeRepos}"
QUIET=0
[ "${2:-}" = "--quiet" ] && QUIET=1

test -d "$SCAN_DIR" || {
  echo "error: $SCAN_DIR is not a directory"
  exit 1
}

HERE=$(cd "$(dirname "$0")/.." && pwd)
RENDER="$HERE/bin/render.sh"
test -x "$RENDER" || {
  echo "error: $RENDER not found"
  exit 1
}

# 60s per repo — render is normally ~3s; anything taking minutes is hung.
TIMEOUT="${RENDER_TIMEOUT:-60}"

declare -a ok chart_dep_auth template_error no_pipelines not_a_repo

total=0
start=$(date +%s)

[ "$QUIET" = "0" ] && echo "Scanning $SCAN_DIR (timeout ${TIMEOUT}s/repo)..."

for d in "$SCAN_DIR"/*/; do
  [ -d "$d" ] || continue
  name=$(basename "$d")
  total=$((total + 1))

  # not-a-repo: nothing useful to inspect
  if [ ! -d "$d/.git" ] && [ ! -f "$d/Chart.yaml" ] && [ ! -d "$d/.lighthouse" ]; then
    not_a_repo+=("$name")
    [ "$QUIET" = "0" ] && printf "  [skip] %s (not a git repo / chart)\n" "$name"
    continue
  fi

  # no-pipelines: out of scope for the harness (no Lighthouse to validate)
  if [ ! -d "$d/.lighthouse/jenkins-x" ]; then
    no_pipelines+=("$name")
    [ "$QUIET" = "0" ] && printf "  [skip] %s (no .lighthouse/jenkins-x/)\n" "$name"
    continue
  fi

  # has-pipelines: try render with a timeout. Capture exit + last line.
  out=$(timeout "$TIMEOUT" "$RENDER" "$d" 2>&1)
  rc=$?

  if [ "$rc" = 0 ]; then
    ok+=("$name")
    [ "$QUIET" = "0" ] && printf "  [ok]   %s\n" "$name"
  elif [ "$rc" = 124 ]; then
    # timeout: classify as template-error but flag the reason
    template_error+=("$name (TIMEOUT)")
    [ "$QUIET" = "0" ] && printf "  [time] %s (render timed out at ${TIMEOUT}s)\n" "$name"
  elif echo "$out" | grep -qE '401 Unauthorized|could not download oci://|failed to fetch oauth token|denied: requested access to the resource is denied|checking for chart dependencies|missing in charts/ directory'; then
    # Private OCI chart registry — auth required. Common on mqube-style
    # repos that depend on charts in jx3mqubebuild.azurecr.io etc.
    # The "checking for chart dependencies" error fires PRE-flight, before
    # helm tries to download — same root cause: deps aren't pulled locally.
    # Engineer with cluster credentials + a `helm dep build` would render
    # cleanly. Not a framework bug.
    chart_dep_auth+=("$name")
    [ "$QUIET" = "0" ] && printf "  [auth] %s (private/missing chart deps)\n" "$name"
  else
    # render failed for non-auth reasons: chart values mismatch, helmfile
    # gotmpl typo, requiredEnv missing, etc. Real consumer-side issue.
    last_err=$(echo "$out" | grep -E 'Error|failed|missing' | tail -1 | head -c 100)
    template_error+=("$name :: $last_err")
    [ "$QUIET" = "0" ] && printf "  [fail] %s :: %s\n" "$name" "$last_err"
  fi
done

elapsed=$(($(date +%s) - start))

# ---- summary ---------------------------------------------------------

echo ""
echo "=== Harness-compatibility survey: $SCAN_DIR ==="
echo ""
printf "  %-22s %4d  %s\n" "ok"                "${#ok[@]}"             "(harness ready, just point at it)"
printf "  %-22s %4d  %s\n" "chart-dep-auth"    "${#chart_dep_auth[@]}" "(private OCI registry — needs cluster creds)"
printf "  %-22s %4d  %s\n" "template-error"    "${#template_error[@]}" "(real chart/helmfile bug or missing config)"
printf "  %-22s %4d  %s\n" "no-pipelines"      "${#no_pipelines[@]}"   "(no .lighthouse — out of scope)"
printf "  %-22s %4d  %s\n" "not-a-repo"        "${#not_a_repo[@]}"     "(skipped — no .git or Chart.yaml)"
printf "  %-22s %4d\n"     "total"             "$total"
echo ""
printf "  scan time: %ds (~%.1fs/repo)\n" "$elapsed" "$(echo "$elapsed $total" | awk '{print $1/$2}')"
echo ""
echo "  Caveats:"
echo "  - 'ok' means render passes (helm template + helmfile build + .lighthouse YAML)."
echo "    Doesn't yet imply 'make test SCENARIO=...' works — that requires the consumer's"
echo "    catalog cloned locally (e.g. ~/leartech/leartech-pipeline-catalog or"
echo "    ~/mqubeRepos/mqube-pipeline-catalog) AND a scenario YAML pointing at it."
echo "  - chart-dep-auth means helm couldn't pull a private OCI chart dep. An engineer"
echo "    authenticated to that registry would render clean — not a framework bug."
echo "  - Different orgs use different catalogs. mqube uses spring-financial-group +"
echo "    upstream jenkins-x; leartech uses mikelear/leartech-pipeline-catalog. Scenario"
echo "    YAMLs are catalog-specific — the framework itself is org-agnostic."
echo ""

if [ "${#ok[@]}" -gt 0 ]; then
  echo "## ok (${#ok[@]})"
  printf '  %s\n' "${ok[@]}"
  echo ""
fi
if [ "${#chart_dep_auth[@]}" -gt 0 ]; then
  echo "## chart-dep-auth (${#chart_dep_auth[@]}) — would render with cluster registry credentials"
  printf '  %s\n' "${chart_dep_auth[@]}"
  echo ""
fi
if [ "${#template_error[@]}" -gt 0 ]; then
  echo "## template-error (${#template_error[@]})"
  printf '  %s\n' "${template_error[@]}"
  echo ""
fi
if [ "${#no_pipelines[@]}" -gt 0 ]; then
  echo "## no-pipelines (${#no_pipelines[@]})"
  printf '  %s\n' "${no_pipelines[@]}"
  echo ""
fi
# not-a-repo is noisy; collapse to count only by default
if [ "${#not_a_repo[@]}" -gt 0 ] && [ "$QUIET" = "0" ]; then
  echo "## not-a-repo (${#not_a_repo[@]}) — collapsed; rerun without --quiet for full list"
fi

# Exit code: 0 if all pipelines-bearing repos either rendered or hit
# expected auth walls; non-zero only if there's a genuine template-error.
[ "${#template_error[@]}" = "0" ] && exit 0 || exit 1
