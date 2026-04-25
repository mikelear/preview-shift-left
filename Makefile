# preview-shift-left: local Tekton-on-kind harness for catalog scripts.
#
#   make up                           # idempotent bootstrap
#   make test SCENARIO=scenarios/...  # run one scenario
#   make list                         # list scenarios
#   make down                         # delete the cluster (registry stays)
#   make nuke                         # full reset: cluster + registry + volumes
#
# Assumes on PATH: kind, kubectl, tkn, yq, jq, openssl, and one of:
# docker (Docker Desktop / Colima / Rancher Desktop) OR podman.

SHELL        := /usr/bin/env bash
.SHELLFLAGS  := -eu -o pipefail -c
.DEFAULT_GOAL := help

CLUSTER       ?= preview-shift-left
CONTEXT       := kind-$(CLUSTER)
KUBECTL       := kubectl --context $(CONTEXT)
REGISTRY_NAME ?= kind-registry
REGISTRY_PORT ?= 5001

# -- container runtime detection --------------------------------------
# Auto-detect docker vs podman. Override with CONTAINER_TOOL=docker|podman.
# Docker CLI covers Docker Desktop, Colima, and Rancher Desktop — they all
# expose the same socket contract, so we don't try to distinguish them here;
# `make doctor` surfaces the actual backend for troubleshooting.
CONTAINER_TOOL ?= $(shell \
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then echo docker; \
  elif command -v podman >/dev/null 2>&1 && podman info >/dev/null 2>&1; then echo podman; \
  else echo none; fi)

# kind picks its container runtime from KIND_EXPERIMENTAL_PROVIDER. We own this
# decision via CONTAINER_TOOL — explicitly override whatever the shell set
# (e.g. a leftover `export KIND_EXPERIMENTAL_PROVIDER=podman` in .zprofile
# would silently make kind try podman even when docker is the live runtime).
ifeq ($(CONTAINER_TOOL),podman)
  export KIND_EXPERIMENTAL_PROVIDER := podman
else
  unexport KIND_EXPERIMENTAL_PROVIDER
endif

# Versions. Bump deliberately; the cluster state hash below invalidates on change.
# Tekton v1.x publishes to ghcr.io. v0.x was on gcr.io/tekton-releases, which
# dropped anonymous pulls in 2026 — older pins will ErrImagePull.
TEKTON_VERSION          ?= v1.6.0
INGRESS_NGINX_MANIFEST  ?= https://kind.sigs.k8s.io/examples/ingress/deploy-ingress-nginx.yaml
MOUNTEBANK_IMAGE        ?= bbyars/mountebank:2.9.1

# Where the catalog lives. Scenarios reference tasks relative to this.
CATALOG_DIR   ?= $(abspath ../leartech-pipeline-catalog)

export CLUSTER CONTEXT CATALOG_DIR MOUNTEBANK_IMAGE CONTAINER_TOOL

.PHONY: help doctor preflight up down nuke ensure-cluster ensure-registry ensure-tekton ensure-ingress test list

help:
	@awk 'BEGIN{FS=":.*?## "}/^[a-zA-Z0-9_-]+:.*## /{printf "  %-20s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

doctor: ## diagnose container runtime + required tooling
	@bin/doctor.sh

preflight:
	@bin/doctor.sh >/dev/null 2>&1 || { bin/doctor.sh; exit 1; }

up: preflight ensure-cluster ensure-registry ensure-tekton ensure-ingress ## bootstrap everything (idempotent)
	@echo "[ok] cluster ready: $(CONTEXT) (runtime: $(CONTAINER_TOOL))"

down: ## delete the kind cluster (registry container keeps running)
	kind delete cluster --name $(CLUSTER)

nuke: down ## full reset — cluster, registry, dangling volumes
	-$(CONTAINER_TOOL) rm -f $(REGISTRY_NAME)
	$(CONTAINER_TOOL) volume prune -f

ensure-cluster:
	@if ! kind get clusters 2>/dev/null | grep -qx $(CLUSTER); then \
	  echo "[..] creating kind cluster $(CLUSTER)"; \
	  kind create cluster --name $(CLUSTER) --config kind.yaml; \
	else \
	  echo "[ok] cluster exists"; \
	fi
	@# Bump inotify limits inside the kind node — multi-step TaskRuns
	@# exhaust the default fs.inotify.max_user_instances (128) and fail
	@# with "too many open files" before any step runs. Idempotent.
	@$(CONTAINER_TOOL) exec $(CLUSTER)-control-plane sysctl -qw \
	  fs.inotify.max_user_instances=8192 \
	  fs.inotify.max_user_watches=524288 2>/dev/null || true

ensure-registry:
	@if ! $(CONTAINER_TOOL) inspect $(REGISTRY_NAME) >/dev/null 2>&1; then \
	  echo "[..] starting local registry on localhost:$(REGISTRY_PORT)"; \
	  $(CONTAINER_TOOL) run -d --restart=always --name $(REGISTRY_NAME) \
	    -p 127.0.0.1:$(REGISTRY_PORT):5000 registry:2 >/dev/null; \
	fi
	@# Attach registry to the kind network so nodes resolve it by name.
	@$(CONTAINER_TOOL) network connect kind $(REGISTRY_NAME) 2>/dev/null || true
	@echo "[ok] registry on localhost:$(REGISTRY_PORT)"

ensure-tekton:
	@if ! $(KUBECTL) get ns tekton-pipelines >/dev/null 2>&1; then \
	  echo "[..] installing Tekton $(TEKTON_VERSION)"; \
	  $(KUBECTL) apply -f https://storage.googleapis.com/tekton-releases/pipeline/previous/$(TEKTON_VERSION)/release.yaml; \
	fi
	@$(KUBECTL) -n tekton-pipelines wait --for=condition=Available \
	  deploy/tekton-pipelines-controller deploy/tekton-pipelines-webhook --timeout=180s >/dev/null
	@echo "[ok] tekton $(TEKTON_VERSION)"

ensure-ingress:
	@if ! $(KUBECTL) get ns ingress-nginx >/dev/null 2>&1; then \
	  echo "[..] installing ingress-nginx"; \
	  $(KUBECTL) apply -f $(INGRESS_NGINX_MANIFEST); \
	fi
	@$(KUBECTL) -n ingress-nginx wait --for=condition=Ready pod \
	  -l app.kubernetes.io/component=controller --timeout=180s >/dev/null
	@echo "[ok] ingress-nginx"

render: ## template-render a consumer repo (no cluster). usage: make render REPO=../leartech-auth-ui
	@test -n "$(REPO)" || { echo "usage: make render REPO=<path-to-consumer-repo>"; exit 2; }
	bin/render.sh $(REPO)

playwright: ## run Playwright specs against a mock UI. usage: make playwright SCENARIO=scenarios/end2end-ui/...yaml
	@test -n "$(SCENARIO)" || { echo "usage: make playwright SCENARIO=scenarios/end2end-ui/<name>.yaml"; exit 2; }
	bin/run-playwright.sh $(SCENARIO)

preview: ## tier 3 — apply consumer preview helmfile. usage: make preview REPO=../leartech-auth-ui [WITH_TLS=1]
	@test -n "$(REPO)" || { echo "usage: make preview REPO=<path-to-consumer-repo> [WITH_TLS=1]"; exit 2; }
	@$(MAKE) -s up
	WITH_TLS=$(WITH_TLS) bin/preview-up.sh $(REPO)

preview-down: ## tear down a preview namespace. usage: make preview-down REPO=../leartech-auth-ui
	@test -n "$(REPO)" || { echo "usage: make preview-down REPO=<path-to-consumer-repo>"; exit 2; }
	@app=$$(basename $$(cd $(REPO) && pwd)); \
	ns=jx-mikelear-$$app-pr-42; \
	$(KUBECTL) delete ns $$ns --wait=false 2>/dev/null || true; \
	echo "[deleted] $$ns"

test: ## run one scenario. usage: make test SCENARIO=scenarios/<path>.yaml [REPO=<path>] [APP_NAME=...]
	@test -n "$(SCENARIO)" || { echo "usage: make test SCENARIO=scenarios/<path>.yaml [REPO=<path>] [APP_NAME=...]"; exit 2; }
	@$(MAKE) -s up
	REPO=$(REPO) APP_NAME=$(APP_NAME) PULL_NUMBER=$(PULL_NUMBER) REPO_OWNER=$(REPO_OWNER) bin/run-scenario.sh $(SCENARIO)

list: ## list scenario files
	@find scenarios -type f -name '*.yaml' | sort

survey: ## scan an org-wide repo dir for harness compat. usage: make survey [DIR=~/mqubeRepos]
	bin/survey.sh $(DIR)

clean-scenarios: ## delete scn-* namespaces left behind by crashed scenarios
	@for ns in $$($(KUBECTL) get ns -o name 2>/dev/null | grep -oE 'scn-[a-z0-9-]+'); do \
	  echo "deleting $$ns"; \
	  $(KUBECTL) delete ns $$ns --wait=false >/dev/null 2>&1; \
	done
	@echo "[ok] scenarios cleaned"
