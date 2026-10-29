#!/usr/bin/env bash
# Build the Falco image and run the smoke test against it.
#
# Usage:
#   ./build.sh                          # build for this machine's platform
#   PLATFORM=linux/amd64 ./build.sh     # e.g. for x86_64 AKS nodes from an arm64 Mac
#   IMAGE=myregistry.azurecr.io/falco TAG=0.45.1-custom ./build.sh
#
# Environment:
#   CONTAINER_TOOL   docker or podman (default: docker if it is running, else podman)
#   IMAGE            image name (default: falco)
#   FALCO_VERSION    Falco release to build on (default: 0.45.1)
#   TAG              image tag (default: $FALCO_VERSION)
#   PLATFORM         target platform, e.g. linux/amd64 (default: native)
#   PULL=1           always pull the latest base images
#   SKIP_TESTS=1     build only
#   SKIP_RUNTIME_TEST=1  passed through to smoke-test.sh

set -euo pipefail

cd "$(dirname "$0")"

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
REF="${IMAGE}:${TAG}"

build_args=(
  --build-arg "FALCO_VERSION=${FALCO_VERSION}"
  # Rulesets (defaults are pinned in the Dockerfile)
  # --build-arg "FALCO_RULES_VERSION=5.2.0"
  # --build-arg "FALCO_INCUBATING_RULES_VERSION=6.0.1"
  # --build-arg "FALCO_SANDBOX_RULES_VERSION=6.2.0"
  # k8saudit-aks plugin, json plugin and k8s audit ruleset (disabled in the Dockerfile for now)
  # --build-arg "K8SAUDIT_AKS_PLUGIN_VERSION=0.6.0"
  # --build-arg "JSON_PLUGIN_VERSION=0.7.4"
  # --build-arg "K8SAUDIT_RULES_VERSION=0.18.0"
)
if [[ -n "${PLATFORM:-}" ]]; then
  build_args+=(--platform "$PLATFORM")
fi
if [[ "${PULL:-0}" == 1 ]]; then
  build_args+=(--pull)
fi

echo "==> Building ${REF} with ${CONTAINER_TOOL}${PLATFORM:+ for ${PLATFORM}}"
"$CONTAINER_TOOL" build "${build_args[@]}" -t "$REF" .

if [[ "${SKIP_TESTS:-0}" == 1 ]]; then
  echo "==> Skipping smoke test"
  exit 0
fi

# The runtime test loads the kernel driver, which needs the image to match the
# host kernel's architecture
native_arch="$("$CONTAINER_TOOL" info --format '{{.Architecture}}' 2>/dev/null || true)"
image_arch="$("$CONTAINER_TOOL" image inspect --format '{{.Architecture}}' "$REF")"
case "$native_arch" in
  x86_64) native_arch=amd64 ;;
  aarch64) native_arch=arm64 ;;
esac
if [[ "$image_arch" != "$native_arch" ]]; then
  echo "==> Image is ${image_arch}, host is ${native_arch}: skipping runtime test"
  export SKIP_RUNTIME_TEST=1
fi

CONTAINER_TOOL="$CONTAINER_TOOL" ./smoke-test.sh "$REF"
