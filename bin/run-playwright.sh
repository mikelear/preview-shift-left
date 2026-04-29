#!/usr/bin/env bash
# bin/run-playwright.sh — run a repo's Playwright specs against a mock UI.
#
# No cluster, no preview. Stands up an nginx container serving the mock UI,
# points the specs at it via PREVIEW_URL, runs playwright from the repo's
# own node_modules, reports pass/fail.
#
# Scenario YAML:
#   kind: playwright-run
#   name: <scenario-id>
#   repo: <relative-path-to-consumer-repo>
#   specs_dir: <optional, defaults to end2end-ui>
#   mock_ui_dir: <optional, defaults to fixtures/playwright/mock-ui>
#   only: [list of spec filenames to run; optional]

set -uo pipefail

SCENARIO="${1:?usage: run-playwright.sh <scenario.yaml>}"
HERE=$(cd "$(dirname "$0")/.." && pwd)
scen_dir=$(cd "$(dirname "$SCENARIO")" && pwd)

name=$(yq -r '.name' "$SCENARIO")
repo_rel=$(yq -r '.repo' "$SCENARIO")
repo=$(cd "$scen_dir" && cd "$repo_rel" && pwd)
specs_rel=$(yq -r '.specs_dir // "end2end-ui"' "$SCENARIO")
specs_dir="$repo/$specs_rel"
base_url_decl=$(yq -r '.base_url // ""' "$SCENARIO")
mock_rel=$(yq -r '.mock_ui_dir // ""' "$SCENARIO")
mock_ui="${mock_rel:+$scen_dir/$mock_rel}"
mock_ui="${mock_ui:-$HERE/fixtures/playwright/mock-ui}"
nginx_conf="$HERE/fixtures/playwright/nginx.conf"

test -d "$specs_dir" || {
  echo "error: specs dir not found: $specs_dir"
  exit 1
}
test -d "$repo/node_modules/playwright" || {
  echo "error: playwright not installed in $repo/node_modules"
  echo "       run 'npm install' in $repo first"
  exit 1
}

echo "[scenario] $name"
echo "[repo]     $repo"
echo "[specs]    $specs_dir"

# Two modes:
#   mock (default)  — spin up nginx + fixtures, specs hit that
#   live            — scenario declares base_url pointing at `make preview`'s
#                     running service; specs hit the real deployment
#
# Headers and cookies stay in Chromium; there's no server-side state shared
# across modes, so the same spec file passes or fails per its own assertions.

if [ -n "$base_url_decl" ]; then
  PREVIEW_URL_VAL="$base_url_decl"
  echo "[mode]     live  -> $PREVIEW_URL_VAL"
else
  test -d "$mock_ui" || {
    echo "error: mock UI dir not found: $mock_ui"
    exit 1
  }
  test -f "$nginx_conf" || {
    echo "error: nginx conf not found: $nginx_conf"
    exit 1
  }
  echo "[mock-ui]  $mock_ui"
  PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("",0)); print(s.getsockname()[1]); s.close()')
  CONTAINER="pw-mock-$(date +%s)-$$"
  # shellcheck disable=SC2329  # Invoked by trap.
  cleanup() { docker stop "$CONTAINER" >/dev/null 2>&1 || true; }
  trap cleanup EXIT
  echo "[mode]     mock  -> localhost:$PORT (container: $CONTAINER)"
  docker run -d --rm --name "$CONTAINER" -p "127.0.0.1:$PORT:80" \
    -v "$mock_ui:/usr/share/nginx/html:ro" \
    -v "$nginx_conf:/etc/nginx/conf.d/default.conf:ro" \
    nginx:alpine >/dev/null
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if curl -sf "http://localhost:$PORT/" >/dev/null 2>&1; then break; fi
    sleep 0.5
    if [ "$i" = "10" ]; then
      echo "error: nginx never became ready on :$PORT"
      docker logs "$CONTAINER" 2>&1 | tail -10
      exit 1
    fi
  done
  PREVIEW_URL_VAL="http://localhost:$PORT"
  echo "[mock-ui]  ready"
fi

# Optional: narrow to a subset of specs.
only_specs=$(yq -r '.only // [] | join(" ")' "$SCENARIO")
workers=$(yq -r '.workers // ""' "$SCENARIO")
workers_arg=""
[ -n "$workers" ] && workers_arg="--workers=$workers"

# Chromium launch args declared per-scenario. Also supports
# ignore_https_errors for self-signed-cert tier-3 previews (PKCE needs
# HTTPS; we ship a self-signed wildcard for *.localtest.me in fixtures/tls/).
chromium_args=$(yq -r '.chromium_args // [] | .[]' "$SCENARIO")
ignore_https=$(yq -r '.ignore_https_errors // false' "$SCENARIO")
if [ -n "$chromium_args" ] || [ "$ignore_https" = "true" ]; then
  # Generate a Playwright config that extends the repo's config with our
  # args. Write into the repo itself so Playwright's config loader resolves
  # the TS import relative path and the repo's own tsconfig/babel hooks
  # pick it up — out-of-tree locations break the import-base path
  # resolution. Unique per-run name avoids collisions; trap cleanup removes.
  pw_config_override="${repo}/playwright.override.${RANDOM}.ts"
  args_json=$(yq -o=json '.chromium_args // []' "$SCENARIO")
  cat >"$pw_config_override" <<EOF
import base from './${specs_rel}/playwright.config';
export default {
  ...base,
  use: {
    ...(base.use || {}),
    ignoreHTTPSErrors: ${ignore_https},
    launchOptions: {
      ...((base.use && base.use.launchOptions) || {}),
      args: [
        ...(((base.use && base.use.launchOptions && base.use.launchOptions.args) || [])),
        ...${args_json}
      ],
    },
  },
};
EOF
  # Clean up on exit so the repo doesn't accumulate overrides.
  # shellcheck disable=SC2064  # Expand $pw_config_override now; by signal time this var may be unset.
  trap "rm -f '$pw_config_override'; ${existing_trap:-true}" EXIT
  config_arg="$pw_config_override"
else
  config_arg="$specs_rel/playwright.config.ts"
fi

# Run Playwright from the repo root (so node_modules is resolved) but
# point --config at the repo's existing playwright.config.ts.
log="/tmp/pw-${name}-$$.log"
echo "[playwright] running specs (log: $log)"

cd "$repo"
set +e
if [ -n "$only_specs" ]; then
  # Convert spec filenames to paths relative to repo root.
  spec_paths=""
  for s in $only_specs; do
    spec_paths="$spec_paths $specs_rel/$s"
  done
  # $workers_arg + $spec_paths intentionally unquoted: $workers_arg is
  # either empty or `--workers=N` (single token; quoting would pass an
  # empty arg when missing); $spec_paths is a space-separated list of
  # paths that needs word-splitting into separate `playwright test` args.
  # shellcheck disable=SC2086
  PREVIEW_URL="$PREVIEW_URL_VAL" \
    npx playwright test \
    --config "$config_arg" $workers_arg \
    $spec_paths 2>&1 | tee "$log"
else
  # shellcheck disable=SC2086  # see comment above re: $workers_arg
  PREVIEW_URL="$PREVIEW_URL_VAL" \
    npx playwright test \
    --config "$config_arg" $workers_arg \
    "$specs_rel" 2>&1 | tee "$log"
fi
rc=${PIPESTATUS[0]}
set -e

passed=$(grep -oE '[0-9]+ passed' "$log" | tail -1 | grep -oE '[0-9]+' || echo 0)
failed=$(grep -oE '[0-9]+ failed' "$log" | tail -1 | grep -oE '[0-9]+' || echo 0)
total=$((passed + failed))

echo ""
echo "-----------------------------------------------"
if [ "$rc" -eq 0 ] && [ "$failed" -eq 0 ]; then
  echo "[ok] playwright: ${passed}/${total:-$passed} passed"
  exit 0
else
  echo "[fail] playwright: ${failed} failed, ${passed} passed (rc=$rc)"
  echo ""
  echo "last 30 lines of log:"
  tail -30 "$log"
  exit 1
fi
