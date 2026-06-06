#!/usr/bin/env bash
# Build the altserver-stack toolchain + engine locally — a fully clean-room build
# with NO Apple corecrypto: the GrandSlam auth crypto is provided by libgsa
# (github.com/dragoshont/libgsa), an OpenSSL/LibreSSL reimplementation. Nothing
# is fetched from developer.apple.com and nothing carries an Apple license.
#
# Requirements: docker with buildx/BuildKit (default on modern Docker).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILDER_TAG="${BUILDER_TAG:-altserver-builder-alpine-amd64:local}"
ENGINE_TAG="${ENGINE_TAG:-altserver-linux:local}"

export DOCKER_BUILDKIT=1

# --- Stage 1: builder toolchain (compiles libgsa + cpprestsdk + libzip) ------
echo "==> building builder toolchain (${BUILDER_TAG})"
docker buildx build \
  --load \
  -t "${BUILDER_TAG}" \
  -f "${REPO_ROOT}/images/builder/Dockerfile" \
  "${REPO_ROOT}/images/builder"

# --- Stage 2: engine (AltServer + patched zsign), linked against the builder --
echo "==> building engine (${ENGINE_TAG}) against ${BUILDER_TAG}"
docker buildx build \
  --load \
  -t "${ENGINE_TAG}" \
  -f "${REPO_ROOT}/images/engine/Dockerfile" \
  --build-arg "BUILDER_IMAGE=${BUILDER_TAG}" \
  "${REPO_ROOT}/images/engine"

cat <<EOF

==> done.
    builder: ${BUILDER_TAG}
    engine:  ${ENGINE_TAG}

Extract the static binaries onto a host:
    docker run --rm -v \$PWD/out:/dest ${ENGINE_TAG} extract

Note: this engine is corecrypto-free — its GrandSlam auth links libgsa
(OpenSSL/LibreSSL). No Apple source is fetched, linked, or shipped.
EOF
