#!/usr/bin/env bash
# Smoke test for the Falco image.
#
# Usage:
#   ./smoke-test.sh                     # tests ${IMAGE}:${TAG}, same defaults as build.sh
#   ./smoke-test.sh falco:0.45.1        # or an explicit image reference
#
# Environment:
#   CONTAINER_TOOL       docker or podman (default: docker if it is running, else podman)
#   IMAGE                image name (default: falco)
#   FALCO_VERSION        used for the default tag (default: 0.45.1)
#   TAG                  image tag (default: $FALCO_VERSION)
#   SKIP_RUNTIME_TEST=1  only run the static checks (no privileged container)
#   RUNTIME_TIMEOUT      seconds to wait for Falco to start / alert (default: 60)

set -euo pipefail

if [[ -z "${CONTAINER_TOOL:-}" ]]; then
  if docker info >/dev/null 2>&1; then
    CONTAINER_TOOL=docker
  elif podman info >/dev/null 2>&1; then
    CONTAINER_TOOL=podman
  else
    echo "error: neither docker nor podman is running" >&2
    exit 1
  fi
fi

IMAGE="${IMAGE:-falco}"
FALCO_VERSION="${FALCO_VERSION:-0.45.1}"
TAG="${TAG:-$FALCO_VERSION}"
REF="${1:-${IMAGE}:${TAG}}"
CT="$CONTAINER_TOOL"
RUNTIME_TIMEOUT="${RUNTIME_TIMEOUT:-60}"
CUSTOM_RULE="Package Manager Run in Container"

pass=0
fail=0
ok()   { echo "  PASS  $*"; pass=$((pass + 1)); }
bad()  { echo "  FAIL  $*"; fail=$((fail + 1)); }
step() { echo; echo "==> $*"; }

run() { "$CT" run --rm "$REF" "$@"; }

if ! "$CT" image inspect "$REF" >/dev/null 2>&1; then
  echo "error: image ${REF} not found, run ./build.sh first" >&2
  exit 1
fi
echo "==> Smoke testing ${REF} with ${CT}"

# The runtime test loads the kernel driver, which needs the image to match the
# host kernel's architecture
native_arch="$("$CT" info --format '{{.Architecture}}' 2>/dev/null || true)"
image_arch="$("$CT" image inspect --format '{{.Architecture}}' "$REF")"
case "$native_arch" in
  x86_64) native_arch=amd64 ;;
  aarch64) native_arch=arm64 ;;
esac
if [[ "$image_arch" != "$native_arch" ]]; then
  echo "==> Image is ${image_arch}, host is ${native_arch}: skipping runtime test"
  SKIP_RUNTIME_TEST=1
fi

# ---- Static checks: no privileges or kernel access needed ----

step "Falco version"
if out="$(run falco --version 2>&1)"; then
  ok "$(echo "$out" | head -1)"
else
  bad "falco --version"; echo "$out"
fi

step "Rule and plugin files present"
files=(
  /etc/falco/falco_rules.yaml
  /etc/falco/rules.d/00-falco-incubating_rules.yaml
  /etc/falco/rules.d/01-falco-sandbox_rules.yaml
  /etc/falco/rules.d/custom_rules.yaml
  /usr/share/falco/plugins/libcontainer.so
  # k8saudit-aks (disabled in the Dockerfile for now)
  # /etc/falco/rules.d/02-k8s_audit_rules.yaml
  # /etc/falco/config.d/falco.k8saudit-aks.yaml
  # /usr/share/falco/plugins/libk8saudit-aks.so
  # /usr/share/falco/plugins/libjson.so
)
for f in "${files[@]}"; do
  if "$CT" run --rm --entrypoint sh "$REF" -c "test -s '$f'" >/dev/null 2>&1; then
    ok "$f"
  else
    bad "$f missing or empty"
  fi
done

step "Config and rules load (falco --dry-run)"
if out="$(run falco --dry-run 2>&1)"; then
  ok "dry run succeeded"
else
  bad "dry run failed"; echo "$out"
fi

step "Rules are listed (falco -L)"
if rules="$(run falco -L 2>&1)"; then
  for r in "Terminal shell in container" "$CUSTOM_RULE"; do
    if grep -qF "$r" <<<"$rules"; then ok "rule: $r"; else bad "rule not loaded: $r"; fi
  done
  # k8s audit ruleset (disabled in the Dockerfile for now)
  # r="Disallowed K8s User"
  # if grep -qF "$r" <<<"$rules"; then ok "rule: $r"; else bad "rule not loaded: $r"; fi
else
  bad "falco -L failed"; echo "$rules"
fi

# k8saudit-aks plugin (disabled in the Dockerfile for now). Dummy connection
# details are enough for Falco to load the plugin and list it; nothing connects.
# step "Plugins load (falco --list-plugins)"
# aks_env=(
#   -e AKS_EVENTHUB_CONNECTION_STRING="Endpoint=sb://smoke.servicebus.windows.net/;SharedAccessKeyName=x;SharedAccessKey=x"
#   -e AKS_EVENTHUB_NAME=smoke
#   -e AKS_BLOB_CONNECTION_STRING="DefaultEndpointsProtocol=https;AccountName=smoke;AccountKey=eA==;EndpointSuffix=core.windows.net"
#   -e AKS_BLOB_CONTAINER_NAME=smoke
# )
# if plugins="$("$CT" run --rm "${aks_env[@]}" "$REF" falco --list-plugins 2>&1)"; then
#   for p in k8saudit-aks json container; do
#     if grep -qE "^Name: ${p}$" <<<"$plugins"; then ok "plugin: $p"; else bad "plugin not loaded: $p"; fi
#   done
# else
#   bad "falco --list-plugins failed"; echo "$plugins"
# fi

# ---- Runtime check: run Falco with the configured driver (engine.kind) and trigger the custom rule ----

if [[ "${SKIP_RUNTIME_TEST:-0}" == 1 ]]; then
  step "Runtime test skipped"
else
  step "Runtime: Falco starts its syscall source and alerts on the custom rule"
  name="falco-smoke-$$"
  cleanup() { "$CT" rm -f "$name" >/dev/null 2>&1 || true; }
  trap cleanup EXIT

  # rule_matching=all: the sandbox rule "Package management process launched in
  # container" matches the same event and loads first, and with the default
  # (first) Falco would stop there before evaluating the custom rule
  "$CT" run -d --name "$name" --privileged \
    -v /var/run/docker.sock:/host/var/run/docker.sock \
    -v /proc:/host/proc:ro \
    -v /etc:/host/etc:ro \
    "$REF" falco -o rule_matching=all >/dev/null

  started=0
  for _ in $(seq "$RUNTIME_TIMEOUT"); do
    if [[ "$("$CT" inspect -f '{{.State.Running}}' "$name" 2>/dev/null)" != true ]]; then
      break
    fi
    if "$CT" logs "$name" 2>&1 | grep -q "Opening 'syscall' source with"; then
      started=1; break
    fi
    sleep 1
  done

  if [[ $started == 1 ]]; then
    ok "$("$CT" logs "$name" 2>&1 | grep -m1 -o "Opening 'syscall' source with.*")"
    # Give the probe a moment to attach, then run a package manager in another container
    sleep 5
    "$CT" run --rm docker.io/library/alpine:3.20 apk --version >/dev/null 2>&1 || true

    alerted=0
    for _ in $(seq "$RUNTIME_TIMEOUT"); do
      if "$CT" logs "$name" 2>&1 | grep -qi "Package manager run in container"; then
        alerted=1; break
      fi
      sleep 1
    done
    if [[ $alerted == 1 ]]; then
      ok "custom rule fired: $("$CT" logs "$name" 2>&1 | grep -i -m1 'Package manager run in container')"
    else
      bad "custom rule did not fire within ${RUNTIME_TIMEOUT}s"
      "$CT" logs "$name" 2>&1 | tail -20
    fi
  else
    bad "Falco did not open its syscall source"
    "$CT" logs "$name" 2>&1 | tail -20
  fi
fi

echo
echo "==> ${pass} passed, ${fail} failed"
[[ $fail == 0 ]]
