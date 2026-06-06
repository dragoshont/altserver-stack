#!/usr/bin/env bash
# Build the altserver-stack toolchain + engine locally — a clean-room build where
# YOU are the party who fetches Apple corecrypto and accepts Apple's terms.
#
# Why build locally instead of pulling the published image:
#   The published ghcr.io/dragoshont/altserver-linux image is a convenience
#   artifact that CONTAINS compiled Apple corecrypto (statically linked into
#   AltServer). corecrypto is fetched from Apple under Apple's *corecrypto
#   Internal Use License* (no-redistribution) and is NOT shipped as source.
#   Building locally keeps that fetch on your machine, under your acceptance.
#
# corecrypto acquisition (handled by images/builder/Dockerfile):
#   1. Bring your own: drop your Apple corecrypto.zip at
#        images/builder/vendor/corecrypto.zip
#      and the build uses it with NO call to developer.apple.com. (.gitignored.)
#   2. Otherwise the build downloads it from Apple and caches it in BuildKit so
#      subsequent local rebuilds skip the download.
#
# Requirements: docker with buildx/BuildKit (default on modern Docker).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILDER_TAG="${BUILDER_TAG:-altserver-builder-alpine-amd64:local}"
ENGINE_TAG="${ENGINE_TAG:-altserver-linux:local}"
VENDOR_ZIP="${REPO_ROOT}/images/builder/vendor/corecrypto.zip"

export DOCKER_BUILDKIT=1

if [ -f "${VENDOR_ZIP}" ]; then
  echo "==> bring-your-own corecrypto: ${VENDOR_ZIP} ($(wc -c < "${VENDOR_ZIP}") bytes) — no Apple download"
else
  echo "==> no vendored corecrypto.zip found."
  echo "    The build will DOWNLOAD corecrypto from Apple; by continuing you accept"
  echo "    Apple's corecrypto Internal Use License. To bring your own instead,"
  echo "    place your Apple corecrypto.zip at:"
  echo "      ${VENDOR_ZIP}"
fi

# --- Stage 1: builder toolchain (compiles corecrypto + cpprestsdk + libzip) --
echo "==> building builder toolchain (${BUILDER_TAG})"
docker buildx build \
  --load \
  -t "${BUILDER_TAG}" \
  -f "${REPO_ROOT}/images/builder/Dockerfile" \
  --build-arg "CORECRYPTO_SHA256=${CORECRYPTO_SHA256:-b0f72ee1235ba791c302922c28be141a4806f7e13d1a1958a51f139d35ad64a9}" \
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

Note: the engine you just built statically links compiled Apple corecrypto,
fetched under Apple's corecrypto Internal Use License (no-redistribution). Keep
it for your own use; do not republish the binary.
EOF
