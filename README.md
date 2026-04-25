# preview-shift-left

Local **kind + Tekton** harness for shifting **JX3 catalog iteration left** — run catalog tasks, Playwright specs, chart renders, and full preview deployments on your laptop in seconds instead of 10-minute PR round-trips.

Designed for leartech's dual-cluster JX3 setup but works for any JX3/Lighthouse-based shop with `preview/helmfile.yaml.gotmpl` consumers.

## Why

Changing a Tekton catalog task (e.g. `tasks/end2end/pullrequest.yaml`) and pushing a PR to iterate takes ~10 min per cluster. For a dual-cluster shop, that's ~20 min per change. Typo in a bash script, revert, re-push — compounds fast. Four iteration speeds here against a local kind cluster:

| Target | Time | What it exercises |
|---|---|---|
| `make render REPO=<path>` | ~3s | Helm chart + helmfile + lighthouse YAML rendering (no cluster) |
| `make playwright SCENARIO=<path>` | ~6–20s | Playwright specs against mock UI or live preview |
| `make test SCENARIO=<path>` | ~30s warm | One catalog task as a live TaskRun with mountebank HTTP stubs |
| `make preview REPO=<path>` | ~2 min warm | Consumer's own `preview/helmfile.yaml.gotmpl` applied to kind |

## Prerequisites

macOS (tested on Apple Silicon) or Linux. Install a container runtime + a handful of CLIs:

- **Container runtime** — one of:
  - Docker Desktop
  - Colima (`brew install colima && colima start`)
  - Rancher Desktop
  - Podman (`brew install podman && podman machine init --rootful && podman machine start`)
- **CLIs** — `kind`, `kubectl`, `tkn` (tektoncd-cli), `helm`, `helmfile`, `yq`, `jq`, `openssl` — all available via `brew install …`

Then `make doctor` tells you what's present, what's missing, and exact fix commands.

## Quick start

Assumes sibling checkouts under `~/leartech/`: `leartech-auth-ui`, `leartech-pipeline-catalog`, plus whatever consumer repos you want to target.

```bash
git clone https://github.com/mikelear/preview-shift-left.git
cd preview-shift-left

# Setup
make doctor                                   # verify runtime + tooling
make up                                       # bootstrap kind + Tekton + ingress + local registry (~2 min cold)

# Tier 1 — render-only checks for a consumer repo (no cluster, ~3s)
make render REPO=../leartech-auth-ui

# Tier 2 — Playwright specs against a mock UI (docker only, ~6s)
make playwright SCENARIO=scenarios/end2end-ui/auth-ui-smoke.yaml

# Tier 2 — catalog task tested locally (kind, ~30s warm).
# One scenario, any consumer — pass REPO=<path> to use that repo's real
# end2end/run.sh, or omit for the scenario's fallback fixture.
make test SCENARIO=scenarios/end2end/gate-ready.yaml                          # default
make test SCENARIO=scenarios/end2end/gate-ready.yaml REPO=../leartech-auth-ui # auth-ui
make test SCENARIO=scenarios/end2end/gate-ready.yaml REPO=../leartech-go-service-template
make test SCENARIO=scenarios/end2end/gate-ready.yaml APP_NAME=foo PULL_NUMBER=99   # ad-hoc env override

# Tier 3 — full preview stack on kind (~2 min cold)
make preview REPO=../leartech-auth-ui          # full OIDC stack (auth-ui + Hydra + auth-service + Mongo)
make playwright SCENARIO=scenarios/end2end-ui/auth-ui-live.yaml  # specs against the live preview

# Teardown
make down                                     # delete the kind cluster (registry persists)
make nuke                                     # full reset
make clean-scenarios                          # delete stale scn-* namespaces from crashed scenarios
```

**Editing the catalog task itself** (e.g. `~/leartech/leartech-pipeline-catalog/tasks/end2end/pullrequest.yaml`) and re-running `make test` picks up the change live — no rebuild, no PR. That's the iteration loop the harness exists for.

**One scenario, N repos.** Adding a new consumer doesn't require a new scenario YAML. Pass `REPO=<path>`. The runner auto-derives `APP_NAME` from the basename, expands `${VAR}` placeholders in the scenario, and pulls `from_repo:` fixtures (e.g. `end2end/run.sh`) from the consumer's actual repo — same files the cluster pipeline uses.

## How scenarios work

Scenarios are the unit of testable work. A scenario is a YAML file that declares what to run against which task or consumer. Three kinds, all in `scenarios/`:

### `task-test` — exercise one catalog task against mountebank stubs

Used for: testing catalog Tekton tasks without pushing a PR. Edit the task, re-run, picks up the change live.

**Repo-agnostic by default.** Use `${VAR}` placeholders + `from_repo` fixtures so one scenario YAML targets N consumer repos without per-repo copies.

```yaml
# scenarios/end2end/gate-ready.yaml
kind: task-test
name: gate-ready
task: ../../../leartech-pipeline-catalog/tasks/end2end/pullrequest.yaml

env:
  APP_NAME: ${APP_NAME}            # auto-derived from REPO basename, or pass APP_NAME=...
  PULL_NUMBER: ${PULL_NUMBER}      # default 42
  REPO_OWNER: ${REPO_OWNER}        # default mikelear
  REPO_NAME: ${REPO_NAME}
  GIT_TOKEN: ${GIT_TOKEN}          # default empty — skips sticky-comment path
  DOMAIN: ${DOMAIN}                # default localtest.me
  CLUSTER_ID: ${CLUSTER_ID}

fixtures:
  .jx/variables.sh:
    template: |                    # `template` — vars expanded at runtime
      export APP_NAME=${APP_NAME}
      export VERSION=${VERSION}
      # ...
  end2end/run.sh:
    from_repo: end2end/run.sh      # `from_repo` — copies $REPO/end2end/run.sh
    fallback: |                     # used when REPO is unset
      #!/usr/bin/env bash
      # minimal always-passing fallback
      ...

stubs:
  - name: preview-gate
    port: 8090
    responses:
      - {method: GET, path: /cgi-bin/gate, status: 200, body: '{"ready":true,"version":"${VERSION}"}'}

expect:
  taskrun_status: Succeeded
  stdout_contains:
    - "gate reports READY"
    - "PASS: end2end complete"
```

Run against any consumer:

```bash
make test SCENARIO=scenarios/end2end/gate-ready.yaml                          # uses fallback fixtures
make test SCENARIO=scenarios/end2end/gate-ready.yaml REPO=../leartech-auth-ui # auth-ui's real end2end/run.sh
make test SCENARIO=scenarios/end2end/gate-ready.yaml APP_NAME=foo PULL_NUMBER=99
```

Variable expansion uses Python's `os.path.expandvars` — only `$NAME` / `${NAME}` shapes are touched (literals like `$1`, `$@`, `$$` pass through), no shell `eval`. Vars not in the environment expand to empty.

### `playwright-run` — Playwright specs against mock or live UI

```yaml
# scenarios/end2end-ui/auth-ui-live.yaml
kind: playwright-run
name: auth-ui-live
repo: ../../../leartech-auth-ui
base_url: https://leartech-auth-ui-pr42.localtest.me:8443   # set = live mode; omit = mock mode
ignore_https_errors: true
workers: 1                                                  # memory-DSN Hydra races under parallel workers
only: [01-page-loads.spec.ts, 02-login-form.spec.ts, 03-login-flow.spec.ts, 05-sign-out.spec.ts, 06-two-factor-setup.spec.ts]
```

### New scenarios, new catalog tasks — no runner changes needed

Drop a YAML in `scenarios/<category>/<name>.yaml` and invoke with `make test SCENARIO=...`. Framework is repo-agnostic: pointing at a different catalog task, different consumer, or different test shape requires only a new scenario file.

## Local substitutions — handling consumer-specific exceptions

Most consumer repos' `preview/helmfile.yaml.gotmpl` runs verbatim against the local cluster. When it doesn't — e.g. a dep that can't resolve locally (arm64-only images, OCI charts needing cluster-registry auth) — ship a substitutions file at:

```
fixtures/local-substitutions/<repo-name>/setup.sh
```

Defines two hook functions and a selector:

```bash
PSL_SELECTOR='name!=auth-mongodb,name!=preview-auth-service'   # helmfile releases to skip
PSL_PROTO='https'                                               # optional: force HTTPS ingress

psl_pre()  { ... }   # runs BEFORE helmfile sync — pre-seed secrets, package charts, etc.
psl_post() { ... }   # runs AFTER — deploy the substitutes, patch ingresses, run seeds
```

`fixtures/local-substitutions/leartech-auth-ui/setup.sh` is the worked example. auth-ui is the **exception**, not the template — its helmfile pulls (a) a bitnami Mongo with no arm64 manifest and (b) the Hydra subchart whose sqlite automigration init container fails on arm64. The substitutions file swaps both for plain-k8s alternatives. For a Go service or simpler MFE, no substitutions file is needed — `make preview` just runs their helmfile.

## Pipelines

`.lighthouse/jenkins-x/triggers.yaml` declares four presubmits, all **non-deploying** (this is a tooling repo, no release/promote):

| Trigger | Catalog source | Runs |
|---|---|---|
| `lint` | inline | shellcheck + shfmt + yamllint |
| `ai-review` | `mikelear/leartech-pipeline-catalog/tasks/ai-review/pullrequest.yaml@main` | LLM code review, sticky PR comment |
| `security-scan` | `mikelear/leartech-pipeline-catalog/tasks/security-scan/pullrequest.yaml@main` | gitleaks + semgrep (static) |
| `ai-feedback` | `mikelear/leartech-pipeline-catalog/tasks/ai-review/feedback.yaml@main` | on-demand `/ai-feedback` comment trigger |

No postsubmits, no release, no image build — just content checks on every PR.

## Known gotchas

- **OIDC + PKCE requires HTTPS** (not cosmetic) — `crypto.subtle.digest` is undefined on plain HTTP non-localhost. The harness generates a self-signed wildcard for `*.localtest.me` in `fixtures/tls/` and patches every ingress with TLS. Playwright scenarios set `ignore_https_errors: true`. Chromium's `--unsafely-treat-insecure-origin-as-secure` flag doesn't propagate through Playwright's `launchOptions.args` — TLS is the reliable fix.
- **Memory-DSN Hydra** wipes state on pod restart. Re-run `make preview REPO=<path>` to re-seed the OAuth client. Serial Playwright (`workers: 1`) avoids races.
- **Colima VM disk is 20 GB by default** — fills up over long sessions. If a kind pod fails with "No space left on device":
  ```bash
  docker exec preview-shift-left-control-plane crictl rmi --prune
  # long-term: colima stop && colima start --disk 60
  ```
- **`~/.zprofile` with `export KIND_EXPERIMENTAL_PROVIDER=podman`** leaks into all shells. The Makefile overrides it internally, but bare `kind …` commands elsewhere will still be affected.
- **Tekton on `gcr.io/tekton-releases`** (v0.x) is 403 anonymous since early 2026. This harness pins `TEKTON_VERSION=v1.6.0` from `ghcr.io`. Your real clusters should too if they haven't already.

## Contributing

PRs welcome. Lighthouse runs the four presubmits above on every PR; green means shellcheck clean, ai-review positive, security-scan clean. `make doctor` before you push.

For internal architectural history and the full findings list, see `Hub/status/preview-shift-left.md` in the leartech hub.

## License

Apache 2.0 (pending — `LICENSE` file to add; matching JX3 ecosystem convention).
