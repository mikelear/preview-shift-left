#!/usr/bin/env bash
# run-scenario.sh — execute one catalog-task scenario against kind + Tekton.
#
# Flow:
#   1. parse scenario (name, task path, env, fixtures, stubs, expect)
#   2. create unique namespace scn-<name>-<rand>
#   3. deploy mountebank with stub imposters + one Service per stub
#   4. seed fixtures: pack tree to tar, stuff into Secret, untar via
#      TaskRun's initContainer (preserves arbitrary directory structure)
#   5. render the catalog task's taskSpec into a TaskRun with env + workspace
#   6. apply, stream logs, wait for completion
#   7. assertions: taskrun status + stdout substring match
#   8. delete namespace (async unless KEEP_NS=1)
#
# Out of MVP: TLS-pinned host stubs (api.github.com etc.), captured-request
# assertions. MVP scenarios should set GIT_TOKEN="" so sticky-comment code
# paths skip cleanly.

set -euo pipefail

SCENARIO="${1:?usage: run-scenario.sh <scenario.yaml>}"
CLUSTER="${CLUSTER:-preview-shift-left}"
CONTEXT="kind-${CLUSTER}"
MOUNTEBANK_IMAGE="${MOUNTEBANK_IMAGE:-bbyars/mountebank:2.9.1}"
K="kubectl --context ${CONTEXT}"
HERE=$(cd "$(dirname "$0")/.." && pwd)

# shellcheck source=bin/preflight.sh
. "$HERE/bin/preflight.sh"
preflight

# ---- scenario parameterisation ---------------------------------------
# Auto-derive APP_NAME / REPO_NAME from REPO=<path> if provided. Lets one
# scenario YAML target N consumer repos via:
#   make test SCENARIO=scenarios/end2end/gate-ready.yaml REPO=../leartech-auth-ui
# Scenario YAML can use ${VAR} placeholders in env values, fixture
# bodies, and stub responses; expanded via Python's expandvars (no shell
# eval, no SC2086-style word-splitting risk).

if [ -n "${REPO:-}" ]; then
  REPO=$(cd "$REPO" && pwd)
  : "${APP_NAME:=$(basename "$REPO")}"
fi
: "${APP_NAME:=leartech-go-service-template}"
: "${REPO_NAME:=$APP_NAME}"
: "${REPO_OWNER:=mikelear}"
: "${PULL_NUMBER:=42}"
: "${DOMAIN:=localtest.me}"
: "${CLUSTER_ID:=local}"
: "${GIT_TOKEN:=}"
: "${VERSION:=0.0.0-PR-${PULL_NUMBER}-1-SNAPSHOT}"
export REPO APP_NAME REPO_NAME REPO_OWNER PULL_NUMBER DOMAIN CLUSTER_ID GIT_TOKEN VERSION

# ${VAR} / $VAR expansion using only os.environ — no shell eval, no
# SC2086 word-splitting risk. Reads stdin, writes stdout. Variables not
# in environment expand to empty (matches `${VAR:-}` shell semantics).
expand_vars() {
  python3 -c 'import os,sys;sys.stdout.write(os.path.expandvars(sys.stdin.read()))'
}

echo "[params]   APP_NAME=$APP_NAME REPO_OWNER=$REPO_OWNER PULL_NUMBER=$PULL_NUMBER DOMAIN=$DOMAIN${REPO:+ REPO=$REPO}"

name=$(yq -r '.name' "$SCENARIO")
task_rel=$(yq -r '.task' "$SCENARIO")
scen_dir=$(cd "$(dirname "$SCENARIO")" && pwd)
task_abs=$(cd "$scen_dir" && cd "$(dirname "$task_rel")" && pwd)/$(basename "$task_rel")
test -f "$task_abs" || {
  echo "error: task file not found: $task_abs"
  exit 1
}

ns="scn-${name//_/-}-$(openssl rand -hex 3)"
echo "[scenario] $name"
echo "[task]     $task_abs"
echo "[ns]       $ns"

$K create ns "$ns" >/dev/null
if [ "${KEEP_NS:-0}" != "1" ]; then
  trap '$K delete ns '"$ns"' --wait=false >/dev/null 2>&1 || true' EXIT
fi

# ---- fixtures: tar -> Secret -----------------------------------------
# Secret chosen over ConfigMap so binaryData handles the tarball
# transparently; also the Secret size limit (1MiB) is plenty for test
# fixtures (typical .jx/variables.sh + a few scripts).

fixtures_json=$(yq -o=json '.fixtures // {}' "$SCENARIO")
fixtures_secret=""
if [ "$fixtures_json" != "{}" ]; then
  tmp=$(mktemp -d)
  # Three fixture shapes supported (back-compat with the original string form):
  #   key: "literal-string"                        — used as-is, with var expansion
  #   key: { template: "..." }                     — expanded via os.path.expandvars
  #   key: { from_repo: "<path>" [, fallback: "..."] }
  #     — copies $REPO/<path> if REPO is set; falls back to inline string otherwise.
  while read -r row; do
    key=$(echo "$row" | base64 -d | jq -r '.key')
    vtype=$(echo "$row" | base64 -d | jq -r '.value | type')
    mkdir -p "$tmp/$(dirname "$key")"

    if [ "$vtype" = "string" ]; then
      content=$(echo "$row" | base64 -d | jq -r '.value' | expand_vars)
    else
      from_repo=$(echo "$row" | base64 -d | jq -r '.value.from_repo // empty')
      template=$(echo "$row" | base64 -d | jq -r '.value.template // empty')
      fallback=$(echo "$row" | base64 -d | jq -r '.value.fallback // empty')

      if [ -n "$from_repo" ] && [ -n "${REPO:-}" ] && [ -f "$REPO/$from_repo" ]; then
        # Read the consumer's actual file. No expansion — it's the file
        # that ships with the consumer and runs on the cluster verbatim.
        content=$(cat "$REPO/$from_repo")
        echo "[fixtures] $key <- \$REPO/$from_repo"
      elif [ -n "$template" ]; then
        content=$(printf '%s' "$template" | expand_vars)
      elif [ -n "$fallback" ]; then
        content=$(printf '%s' "$fallback" | expand_vars)
      else
        echo "error: fixture $key has from_repo=$from_repo but \$REPO not set or file missing, no fallback declared"
        exit 1
      fi
    fi

    printf '%s' "$content" >"$tmp/$key"
    # Mark likely scripts executable so the task's `bash end2end/run.sh`
    # (or `[ -x end2end/run.sh ]` checks) still work after untar.
    case "$key" in
      *.sh) chmod +x "$tmp/$key" ;;
    esac
  done < <(echo "$fixtures_json" | jq -r 'to_entries[] | @base64')

  tarball=$(mktemp)
  tar -czf "$tarball" -C "$tmp" .
  $K -n "$ns" create secret generic scenario-fixtures \
    --from-file=fixtures.tar.gz="$tarball" >/dev/null
  fixtures_secret="scenario-fixtures"
  rm -rf "$tmp" "$tarball"
  echo "[fixtures] $(echo "$fixtures_json" | jq 'keys | length') file(s) seeded"
fi

# ---- stubs: mountebank -----------------------------------------------
# One mountebank pod in the scenario namespace hosts all imposters.
# Each stub becomes a Service at its declared name so in-cluster DNS
# like preview-gate.<ns>.svc.cluster.local resolves.

# Stub bodies often embed APP_NAME / VERSION / etc. — expand placeholders.
stubs_json=$(yq -o=json '.stubs // []' "$SCENARIO" | expand_vars)
stub_count=$(echo "$stubs_json" | jq 'length')

if [ "$stub_count" -gt 0 ]; then
  echo "[stubs]    $stub_count stub(s)"

  # Build a mountebank imposters.json from the scenario's stubs.
  # For each stub we emit one imposter on its declared port.
  imposters_json=$(echo "$stubs_json" | jq '{
    imposters: [.[] | {
      port: .port,
      protocol: "http",
      stubs: [.responses[] | {
        predicates: [
          (if .method then {equals: {method: .method}} else null end),
          (if .path   then {equals: {path: .path}}     else null end)
        ] | map(select(. != null)),
        responses: [{
          is: {
            statusCode: .status,
            body: .body,
            headers: {"Content-Type": "application/json"}
          }
        }]
      }]
    }]
  }')

  # Apply: ConfigMap with imposters, Deployment, Service per stub.
  stub_services=$(echo "$stubs_json" | jq -r '.[] | "\(.name)|\(.port)"')

  # Build service manifests from the list.
  services_yaml=""
  while IFS='|' read -r stub_name stub_port; do
    [ -z "$stub_name" ] && continue
    services_yaml+="
---
apiVersion: v1
kind: Service
metadata:
  name: ${stub_name}
spec:
  selector:
    app: mountebank
  ports:
  - port: ${stub_port}
    targetPort: ${stub_port}
    protocol: TCP
    name: http-${stub_port}
"
  done <<<"$stub_services"

  cat <<EOF | $K -n "$ns" apply -f - >/dev/null
apiVersion: v1
kind: ConfigMap
metadata:
  name: mountebank-imposters
data:
  imposters.json: |
$(echo "$imposters_json" | sed 's/^/    /')
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mountebank
  labels:
    app: mountebank
spec:
  replicas: 1
  selector:
    matchLabels:
      app: mountebank
  template:
    metadata:
      labels:
        app: mountebank
    spec:
      containers:
      - name: mountebank
        image: ${MOUNTEBANK_IMAGE}
        args: ["--configfile", "/config/imposters.json", "--allowInjection"]
        ports:
$(echo "$stubs_json" | jq -r '.[] | "        - containerPort: \(.port)\n          name: http-\(.port)"')
        volumeMounts:
        - name: imposters
          mountPath: /config
      volumes:
      - name: imposters
        configMap:
          name: mountebank-imposters
${services_yaml}
EOF

  $K -n "$ns" wait --for=condition=Available deploy/mountebank --timeout=60s >/dev/null
  echo "[stubs]    mountebank ready"
fi

# ---- TaskRun ---------------------------------------------------------
# Pull the taskSpec out of the catalog PipelineRun YAML and wrap it in a
# TaskRun. Merge scenario env into stepTemplate.env. Add:
#   - emptyDir workspace at /workspace/source
#   - initContainer that untars the fixtures tarball into the workspace

# Expand ${VAR} placeholders in env values (e.g. APP_NAME, PULL_NUMBER).
env_json=$(yq -o=json '.env // {}' "$SCENARIO" | expand_vars)

# In-cluster DNS fidelity via hostAliases:
# Catalog task scripts hardcode hostnames like
#   preview-gate.jx-<OWNER>-<APP>-pr-<N>.svc.cluster.local
# built from env vars, with NO fallback to PREVIEW_NAMESPACE env. Setting
# PREVIEW_NAMESPACE would be overwritten. Instead, we add /etc/hosts
# entries on the TaskRun pod that map the expected JX-formula hostname
# to the mountebank pod IP — so `curl <host>:<port>` lands on the stub.
host_aliases_yaml=""
if [ "$stub_count" -gt 0 ]; then
  mb_pod_ip=$($K -n "$ns" get pod -l app=mountebank -o jsonpath='{.items[0].status.podIP}')
  owner=$(echo "$env_json" | jq -r '.REPO_OWNER // ""')
  app=$(echo "$env_json" | jq -r '.APP_NAME   // ""')
  pr=$(echo "$env_json" | jq -r '.PULL_NUMBER // ""')
  if [ -n "$owner" ] && [ -n "$app" ] && [ -n "$pr" ]; then
    task_ns="jx-${owner}-${app}-pr-${pr}"
    # Build alias hostnames: <stub-name>.<task-ns>.svc.cluster.local
    aliases=$(echo "$stubs_json" | jq -r --arg ns "$task_ns" \
      '[.[] | "\(.name).\($ns).svc.cluster.local"] | @json')
    host_aliases_yaml="
  podTemplate:
    hostAliases:
    - ip: ${mb_pod_ip}
      hostnames: ${aliases}"
    echo "[hosts]    aliasing ${aliases} -> ${mb_pod_ip}"
  fi
fi

# Extract the embedded taskSpec. Catalogs use two shapes:
#   kind: PipelineRun  → taskSpec at .spec.pipelineSpec.tasks[0].taskSpec
#                        (leartech catalog convention; 11 of mqube's tasks)
#   kind: Task         → taskSpec at .spec
#                        (62 of mqube's tasks)
task_kind=$(yq -r '.kind' "$task_abs")
case "$task_kind" in
  PipelineRun)
    task_spec=$(yq -o=yaml '.spec.pipelineSpec.tasks[0].taskSpec' "$task_abs")
    ;;
  Task)
    task_spec=$(yq -o=yaml '.spec' "$task_abs")
    ;;
  *)
    echo "error: unsupported task kind: $task_kind (expected PipelineRun or Task)"
    exit 1
    ;;
esac

tr_name="scenario-$(openssl rand -hex 3)"

# Build the TaskRun YAML. We let yq merge the taskSpec in cleanly.
tmp_tr=$(mktemp)
cat >"$tmp_tr" <<EOF
apiVersion: tekton.dev/v1
kind: TaskRun
metadata:
  name: ${tr_name}
spec:
  serviceAccountName: default
  workspaces:
  - name: source
    emptyDir: {}${host_aliases_yaml}
  taskSpec:
$(echo "$task_spec" | sed 's/^/    /')
EOF

# Rewrite the taskSpec in-place to:
#   a) drop v1beta1-only fields the v1 webhook rejects (metadata, resources)
#   b) declare a workspace
#   c) inject scenario env into stepTemplate.env
#   d) add an initContainer (as a first step) that untars fixtures
#
# Tekton v1 TaskRun taskSpec supports .workspaces, .steps, .stepTemplate.
# The catalog files use v1beta1 shape under .spec.pipelineSpec.tasks[0].taskSpec
# which is Task-spec-shaped. Fields we touch: stepTemplate.env, steps[].
yq -i '
  del(.spec.taskSpec.metadata)
  | del(.spec.taskSpec.stepTemplate.resources)
  | del(.spec.taskSpec.stepTemplate.name)
  | .spec.taskSpec.steps |= map(del(.resources) | del(select(.name == "") | .name))
  | .spec.taskSpec.workspaces = [{"name": "source", "mountPath": "/workspace/source"}]
  | .spec.workspaces = [{"name": "source", "emptyDir": {}}]
' "$tmp_tr"

# Merge env
if [ "$env_json" != "{}" ]; then
  env_merge=$(echo "$env_json" | jq 'to_entries | map({name: .key, value: (.value|tostring)})')
  # Ensure stepTemplate.env exists (might be absent or pre-populated).
  yq -i ".spec.taskSpec.stepTemplate.env = (.spec.taskSpec.stepTemplate.env // []) + ${env_merge}" "$tmp_tr"
fi

# Prepend a fixture-seed initContainer as the first step IF fixtures declared.
if [ -n "$fixtures_secret" ]; then
  yq -i "
    .spec.taskSpec.volumes = (.spec.taskSpec.volumes // []) + [{
      \"name\": \"fixture-tar\",
      \"secret\": {\"secretName\": \"${fixtures_secret}\"}
    }]
    | .spec.taskSpec.steps = [{
      \"name\": \"seed-fixtures\",
      \"image\": \"alpine:3.20\",
      \"workingDir\": \"/workspace/source\",
      \"volumeMounts\": [{\"name\": \"fixture-tar\", \"mountPath\": \"/fixtures\", \"readOnly\": true}],
      \"script\": \"#!/bin/sh\nset -e\ntar -xzf /fixtures/fixtures.tar.gz -C /workspace/source\nls -la /workspace/source\n\"
    }] + .spec.taskSpec.steps
  " "$tmp_tr"
fi

# Strip setup steps the harness replaces:
#   - git-clone-pr  (no PR to clone — fixtures provide the files)
#   - jx-variables  (generates .jx/variables.sh from git context — fixtures
#                    provide this directly, via .jx/variables.sh)
# The task's "real" logic (the step with the bash script we want to test)
# is what's left.
yq -i '
  .spec.taskSpec.steps |= map(
    select(
      (.image  // "" | test("uses:.*/git-clone/") | not)
      and (.name // "" != "jx-variables")
    )
  )
' "$tmp_tr"

echo "[taskrun]  applying $tr_name"
$K -n "$ns" apply -f "$tmp_tr" >/dev/null
rm -f "$tmp_tr"

# ---- stream logs + wait for completion -------------------------------

log="/tmp/scn-${ns}.log"
# tkn blocks until the TaskRun completes, streaming step logs as they run.
tkn --context "$CONTEXT" -n "$ns" taskrun logs -f "$tr_name" 2>&1 | tee "$log"

status=$($K -n "$ns" get taskrun "$tr_name" \
  -o jsonpath='{.status.conditions[?(@.type=="Succeeded")].status}' 2>/dev/null || echo Unknown)
reason=$($K -n "$ns" get taskrun "$tr_name" \
  -o jsonpath='{.status.conditions[?(@.type=="Succeeded")].reason}' 2>/dev/null || echo Unknown)

echo ""
echo "[taskrun]  status=$status reason=$reason"

# ---- assertions ------------------------------------------------------

want_status=$(yq -r '.expect.taskrun_status // "Succeeded"' "$SCENARIO")
expected_status="True"

# `taskrun_status: "*"` opts out of status checking — useful for cross-org
# / cross-arch demo scenarios where the task is expected to hang or
# fail at a step we can't fix locally (e.g. kaniko amd64-only build on
# arm64 host). Only stdout_contains assertions matter; `tkn` will be
# killed after the stdout assertions pass to avoid waiting for timeout.
if [ "$want_status" = "*" ]; then
  echo "[assert]  taskrun_status: skipped (scenario opts out via '*')"
fi
[ "$want_status" = "Failed" ] && expected_status="False"

fails=0
if [ "$want_status" = "*" ]; then
  :  # skipped
elif [ "$status" = "$expected_status" ]; then
  echo "  [pass]  taskrun_status=$want_status"
else
  echo "  [fail]  taskrun_status=$want_status (got $status/$reason)"
  fails=$((fails + 1))
fi

while read -r expected; do
  [ -z "$expected" ] && continue
  if grep -qF -- "$expected" "$log"; then
    echo "  [pass]  stdout_contains: \"$expected\""
  else
    echo "  [fail]  stdout_contains: \"$expected\" (not in log)"
    fails=$((fails + 1))
  fi
done < <(yq -r '.expect.stdout_contains // [] | .[]' "$SCENARIO" | expand_vars)

echo ""
if [ "$fails" -eq 0 ]; then
  echo "[ok] scenario passed"
  exit 0
else
  echo "[fail] $fails assertion(s) failed"
  echo "log: $log"
  exit 1
fi
