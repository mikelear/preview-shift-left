#!/usr/bin/env bash
# bin/doctor.sh — diagnose container runtime health and missing tooling.
#
# Exits 0 if at least one runtime (docker or podman) is usable.
# Exits 1 otherwise, after printing a specific start command for whatever
# IS installed but not running, rather than a generic "install something".
#
# Distinguishes:
#   - runtime not installed                -> install instructions
#   - runtime installed but stopped        -> start instructions
#   - runtime running but kind-incompatible (rootless podman) -> upgrade steps

set -uo pipefail

has() { command -v "$1" >/dev/null 2>&1; }
say() { printf "  %-14s %s\n" "$1" "$2"; }

# -- probe -------------------------------------------------------------

docker_installed=0; docker_ok=0; docker_ctx=""; docker_backend=""
podman_installed=0; podman_ok=0
colima_installed=0; colima_running=0
podman_machine_present=0; podman_machine_running=0; podman_machine_rootful=0

if has docker; then
  docker_installed=1
  docker_ctx=$(docker context show 2>/dev/null || echo default)
  if docker info >/dev/null 2>&1; then
    docker_ok=1
    docker_backend=$(docker info --format '{{.OperatingSystem}}' 2>/dev/null)
  fi
fi

if has podman; then
  podman_installed=1
  podman info >/dev/null 2>&1 && podman_ok=1
  # Machine state matters on macOS/Windows (Linux runs podman natively).
  case "$(uname)" in
    Darwin|Windows*|MINGW*|MSYS*)
      mline=$(podman machine list --format '{{.Name}} running={{.Running}} rootful={{.Rootful}}' 2>/dev/null | head -1)
      if [ -n "$mline" ]; then
        podman_machine_present=1
        echo "$mline" | grep -q 'running=true' && podman_machine_running=1
        echo "$mline" | grep -q 'rootful=true' && podman_machine_rootful=1
      fi
      ;;
  esac
fi

if has colima; then
  colima_installed=1
  colima status >/dev/null 2>&1 && colima_running=1
fi

# -- report ------------------------------------------------------------

echo "Runtime detection:"

if [ $docker_installed = 1 ]; then
  say "docker:" "$(command -v docker)"
  say "  context:" "$docker_ctx"
  if [ $docker_ok = 1 ]; then
    say "  status:" "OK (backend: ${docker_backend:-unknown})"
  else
    say "  status:" "not responding (daemon / VM not running)"
  fi
fi

if [ $podman_installed = 1 ]; then
  say "podman:" "$(command -v podman)"
  if [ $podman_ok = 1 ]; then
    say "  status:" "OK"
  else
    say "  status:" "not responding"
  fi
  if [ $podman_machine_present = 1 ]; then
    state="stopped"; [ $podman_machine_running = 1 ] && state="running"
    mode="rootless"; [ $podman_machine_rootful = 1 ] && mode="rootful"
    say "  machine:" "$state / $mode"
  fi
fi

if [ $colima_installed = 1 ]; then
  cstat=$(colima status 2>&1 | head -1 | sed 's/^[^ ]* level=[a-z]* msg=//; s/^"//; s/"$//')
  say "colima:" "${cstat:-unknown}"
fi

if [ $docker_installed = 0 ] && [ $podman_installed = 0 ] && [ $colima_installed = 0 ]; then
  say "(none)" "no docker/podman/colima CLI found on PATH"
fi

# -- decide ------------------------------------------------------------

echo ""

if [ $docker_ok = 1 ]; then
  echo "VERDICT: use docker (CONTAINER_TOOL=docker)"
  tool_ok=1
elif [ $podman_ok = 1 ]; then
  echo "VERDICT: use podman (CONTAINER_TOOL=podman)"
  tool_ok=1
  if [ $podman_machine_running = 1 ] && [ $podman_machine_rootful = 0 ]; then
    cat <<EOF

  WARNING: podman machine is rootless; kind typically needs rootful mode.
    Fix once:
      podman machine stop
      podman machine set --rootful
      podman machine start
EOF
  fi
else
  tool_ok=0
  echo "VERDICT: no runtime currently usable."
  echo ""
  echo "Start one of what's already installed:"

  if [ $colima_installed = 1 ] && [ $colima_running = 0 ]; then
    if [ "$docker_ctx" = "colima" ]; then
      echo "  colima (your docker context points here — fastest fix):"
    else
      echo "  colima:"
    fi
    echo "      colima start"
  fi

  if [ $podman_installed = 1 ] && [ $podman_machine_running = 0 ]; then
    if [ $podman_machine_present = 1 ]; then
      echo "  podman (machine exists, stopped):"
      echo "      podman machine start"
      if [ $podman_machine_rootful = 0 ]; then
        echo "      # then switch to rootful for kind compatibility:"
        echo "      podman machine stop && podman machine set --rootful && podman machine start"
      fi
    else
      echo "  podman (no machine yet):"
      echo "      podman machine init --rootful && podman machine start"
    fi
  fi

  if [ $docker_installed = 1 ] && [ $docker_ok = 0 ] \
     && [ "$docker_ctx" != "colima" ] \
     && [ $colima_installed = 0 ] && [ $podman_installed = 0 ]; then
    echo "  docker (CLI present, daemon unreachable):"
    echo "      open Docker Desktop, or: docker context use default"
  fi

  if [ $docker_installed = 0 ] && [ $podman_installed = 0 ] && [ $colima_installed = 0 ]; then
    cat <<EOF
  Nothing installed. Pick one:
    brew install colima     && colima start
    brew install podman     && podman machine init --rootful && podman machine start
    Docker Desktop          https://www.docker.com/products/docker-desktop
EOF
  fi
fi

# -- companion tools ---------------------------------------------------

echo ""
echo "Required tooling:"
missing=0
# Some brew formulas don't match their binary name.
brew_formula() {
  case "$1" in
    tkn) echo tektoncd-cli ;;
    *)   echo "$1" ;;
  esac
}
for bin in kind kubectl tkn helm helmfile yq jq openssl; do
  if has "$bin"; then
    say "$bin:" "$(command -v "$bin")"
  else
    say "$bin:" "MISSING (brew install $(brew_formula "$bin"))"
    missing=1
  fi
done

echo ""
if [ ${tool_ok:-0} = 1 ] && [ $missing = 0 ]; then
  echo "[ok] ready for: make up"
  exit 0
fi
exit 1
