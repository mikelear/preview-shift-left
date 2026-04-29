#!/usr/bin/env bash
# bin/preflight.sh — resource sanity check before Tier 2/3 runs.
#
# Sourced (not exec'd) by preview-up.sh and run-scenario.sh. Never aborts —
# warning only, because transient disk/memory pressure clears on its own and
# a hard fail would block iteration. Two checks:
#
#   1. Colima VM /dev/root free space — the real constraint. The kind node's
#      reported `df /` overlay is misleading (includes Mac's /Users virtiofs
#      mount; see status finding #13).
#   2. kubelet's DiskPressure / MemoryPressure node conditions.
#
# Output: one line to stdout. If either signal trips, two recovery hints.

preflight() {
  local cluster="${CLUSTER:-preview-shift-left}"
  local context="${CONTEXT:-kind-$cluster}"
  local warn=0
  local line="[preflight]"

  # The constraint is the docker DATA disk (vdb1 = /var/lib/docker = 100G
  # by default on Colima), NOT the Colima system disk (vda1 = / = 19G).
  # Check from inside the kind node — that's exactly the surface that
  # `docker build` + `kind load` will hit.
  if docker exec "${cluster}-control-plane" true 2>/dev/null; then
    local df_out size_kb free_kb free_h size_h
    df_out=$(docker exec "${cluster}-control-plane" df -k /var 2>/dev/null | awk 'NR==2 {print $2, $4}')
    if [ -n "$df_out" ]; then
      size_kb=${df_out% *}
      free_kb=${df_out#* }
      free_h=$(awk -v k="$free_kb" 'BEGIN{printf "%.0fG", k/1024/1024}')
      size_h=$(awk -v k="$size_kb" 'BEGIN{printf "%.0fG", k/1024/1024}')
      if [ "$free_kb" -lt 5242880 ]; then # < 5G
        warn=1
        line="$line  docker-data: ⚠ ${free_h}/${size_h} free (LOW)"
      else
        line="$line  docker-data: ${free_h}/${size_h} free"
      fi
    fi
  fi

  # kubelet pressure (skip if cluster not reachable)
  if kubectl --context "$context" get nodes >/dev/null 2>&1; then
    local pressure
    pressure=$(kubectl --context "$context" get nodes -o json 2>/dev/null \
      | jq -r '.items[0].status.conditions[]
             | select((.type=="DiskPressure" or .type=="MemoryPressure") and .status=="True")
             | .type' 2>/dev/null | tr '\n' ',' | sed 's/,$//')
    if [ -n "$pressure" ]; then
      warn=1
      line="$line  |  kubelet: ⚠ $pressure"
    else
      line="$line  |  kubelet: ok"
    fi
  fi

  echo "$line"

  if [ "$warn" = "1" ]; then
    echo "[preflight] recovery (most → least targeted):"
    echo "[preflight]   docker exec ${cluster}-control-plane crictl rmi --prune    # in-cluster cache"
    echo "[preflight]   docker image prune -af                                      # host docker (unused)"
    echo "[preflight]   docker system prune -af --volumes                           # host docker (everything unused)"
  fi
}
