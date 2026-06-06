# syntax=docker/dockerfile:1
#
# AltServer-Linux build toolchain (Alpine 3.15 + static deps) — PINNED.
#
# Vendoring
# ---------
# This is a hard-fork of NyaMisty/AltServer-Linux//buildenv/Dockerfile, the image
# that used to ship as ghcr.io/nyamisty/altserver_builder_alpine_amd64. NyaMisty's
# repo is dead (last release Apr 2022) so we vendor the toolchain here, build it in
# our own CI, and publish it to ghcr.io/dragoshont/altserver-builder-alpine-amd64.
# This was the last NyaMisty-owned artifact in the AltServer-Linux build chain; with
# it vendored, nothing in the engine build resolves to a deletable upstream account.
#
# Pinning (reproducibility)
# -------------------------
# Upstream cloned cpprestsdk + libzip at HEAD-of-the-day and pulled corecrypto
# live, so two builds months apart could differ. We pin both git deps to the
# release SHAs that were current when the upstream toolchain last worked (~Apr
# 2022): cpprestsdk v2.10.18 and libzip v1.8.0. corecrypto is a binary zip served
# by developer.apple.com that has no version handle — it stays a live fetch but is
# overridable (CORECRYPTO_URL) and guarded by an optional SHA256 check
# (CORECRYPTO_SHA256 empty = skip). Bump any pin via --build-arg.
#
# What it provides
# ----------------
# Alpine 3.15 + the compilers (g++, clang, cmake, ninja, make), Boost (static),
# and three from-source static libraries that AltServer-Linux links against:
#   * Apple corecrypto   (CORECRYPTO_URL, live Apple zip)
#   * Microsoft cpprestsdk (CPPRESTSDK_REF @ v2.10.18, static)
#   * nih-at/libzip        (LIBZIP_REF @ v1.8.0, static)
# The main engine Dockerfile (../engine/Dockerfile) uses this image as its
# `altserver-build` stage base via the BUILDER_IMAGE ARG.
#
# Pinned to amd64/alpine:3.15 — the host (and the engine runtime image) are amd64.

ARG IMAGE=amd64/alpine:3.15

FROM $IMAGE

# --- pinned dependency refs -------------------------------------------------
ARG CPPRESTSDK_REPO=https://github.com/microsoft/cpprestsdk
ARG CPPRESTSDK_REF=122d09549201da5383321d870bed45ecb9e168c5
ARG LIBZIP_REPO=https://github.com/nih-at/libzip
ARG LIBZIP_REF=26ba5523db09213f532821875542dba7afa04b65
# corecrypto has no version handle on Apple's side and Apple silently revs it.
# Pin the digest of the artifact we built against (captured 2026-06-06, extracts
# as corecrypto-2024/). The build fails loudly if Apple ships a different zip;
# set CORECRYPTO_SHA256='' to bypass when intentionally adopting a new drop.
ARG CORECRYPTO_URL='https://developer.apple.com/file/?file=security&agree=Yes'
ARG CORECRYPTO_SHA256=b0f72ee1235ba791c302922c28be141a4806f7e13d1a1958a51f139d35ad64a9

RUN  apk add zsh git curl wget g++ clang boost-static ninja boost-dev cmake make sudo bash vim libressl-dev util-linux-dev zlib-dev zlib-static

RUN mkdir /buildenv

WORKDIR /buildenv

# --- Apple corecrypto (download-not-deliver, cacheable, BYO-able) -----------
# corecrypto is Apple SOURCE (not a prebuilt binary): we COMPILE it here into a
# static archive that the engine later links. Apple's *corecrypto Internal Use
# License* forbids redistributing the source, so we never commit/ship the zip —
# it is fetched from developer.apple.com at build time, and whoever runs this
# build accepts Apple's terms by doing so.
#
# Acquisition order (check-then-download):
#   1. If images/builder/vendor/corecrypto.zip is present in the build context
#      (COPYed to /vendor below), use it — this is "bring your own corecrypto"
#      for users who downloaded it from Apple themselves and do NOT want this
#      build calling developer.apple.com. Works with plain `docker build`.
#   2. Else if /cccache/corecrypto.zip exists (a BuildKit cache mount that
#      persists across local rebuilds), use it — no re-download.
#   3. Otherwise download from Apple and save a copy back into /cccache so the
#      next build skips the download.
# The integrity guard (CORECRYPTO_SHA256) is applied to ALL paths, so a stale,
# substituted, or BYO zip fails just as loudly as a drifted Apple download.
#
# Layout fix-ups (Apple silently revs this with no version handle): the zip used
# to extract to corecrypto/ but now lands as corecrypto-2024/ (plus __MACOSX/
# junk) — normalize whatever versioned top-level dir ships into a stable
# /buildenv/corecrypto. Its CMakeLists.txt also `include(scripts/code-coverage.cmake)`
# — a StableCoder helper Apple references but does NOT ship; it only feeds the
# default-off CODE_COVERAGE option, so strip the include + add/target_code_coverage
# calls. Apple's generated CoreCryptoSources.cmake lists ccrng_static.c under a
# corecrypto_static/ subdir the public zip does NOT ship (the file is at the tree
# root) — rewrite that one path so add_library(corecrypto_static) resolves.
#
# vendor/ always exists (it has a README) so this COPY never fails; a user's
# BYO corecrypto.zip dropped in there is .gitignored and never committed.
COPY vendor/ /vendor/
RUN --mount=type=cache,target=/cccache,sharing=locked \
    if [ -f /vendor/corecrypto.zip ]; then \
        echo "== using bring-your-own corecrypto.zip from build context /vendor (no Apple download) =="; \
        cp /vendor/corecrypto.zip corecrypto.zip; \
    elif [ -f /cccache/corecrypto.zip ]; then \
        echo "== using cached corecrypto.zip from /cccache (no Apple download) =="; \
        cp /cccache/corecrypto.zip corecrypto.zip; \
    else \
        echo "== no vendored/cached corecrypto.zip — downloading from Apple (by doing so you accept Apple's corecrypto Internal Use License) =="; \
        curl -JL -o corecrypto.zip "${CORECRYPTO_URL}" -H 'Referer: https://developer.apple.com/security/' \
        && cp corecrypto.zip /cccache/corecrypto.zip; \
    fi \
 && if [ -n "${CORECRYPTO_SHA256}" ]; then \
        echo "${CORECRYPTO_SHA256}  corecrypto.zip" | sha256sum -c - \
        || { echo "ERROR: corecrypto.zip digest != pinned CORECRYPTO_SHA256 — delete the cached copy (/cccache/corecrypto.zip), fix vendor/corecrypto.zip, or pass a new CORECRYPTO_SHA256"; exit 1; }; \
    else \
        echo "WARN: CORECRYPTO_SHA256 not set — skipping corecrypto integrity check"; sha256sum corecrypto.zip; \
    fi \
 && unzip -q corecrypto.zip \
 && rm -rf __MACOSX \
 && cml="$(find . -maxdepth 2 -name CMakeLists.txt -path '*corecrypto*' 2>/dev/null | head -n1)" \
 && test -n "$cml" || { echo "ERROR: no corecrypto CMakeLists.txt found after unzip"; ls -la; exit 1; } \
 && src="$(dirname "$cml")" \
 && echo "== corecrypto source dir: $src ==" \
 && if [ "$src" != "./corecrypto" ]; then rm -rf corecrypto && mv "$src" corecrypto; fi \
 && sed -i -E '/include\(scripts\/code-coverage\.cmake\)/d; /add_code_coverage\(\)/d; /target_code_coverage\(/d' corecrypto/CMakeLists.txt \
 && sed -i 's#"corecrypto_static/ccrng_static.c"#"ccrng_static.c"#' corecrypto/CoreCryptoSources.cmake
WORKDIR /buildenv/corecrypto
RUN mkdir build; cd build; CC=clang CXX=clang++ cmake ..;
WORKDIR /buildenv/corecrypto/build
RUN sed -i -E 's|^(all: CMakeFiles\/corecrypto_perf)|#\1|' CMakeFiles/Makefile2; sed -i -E 's|^(all: CMakeFiles\/corecrypto_test)|#\1|' CMakeFiles/Makefile2
RUN make -j6; make install

WORKDIR /buildenv

# --- Microsoft cpprestsdk @ v2.10.18 (static) -------------------------------
RUN git clone "${CPPRESTSDK_REPO}" cpprestsdk \
 && git -C cpprestsdk checkout "${CPPRESTSDK_REF}" \
 && git -C cpprestsdk submodule update --init --recursive
WORKDIR /buildenv/cpprestsdk
RUN sed -i 's|-Wcast-align||' "./Release/CMakeLists.txt"
RUN mkdir build; cd build; cmake -DBUILD_SHARED_LIBS=0 ..; make -j6; make install

WORKDIR /buildenv/

# --- nih-at/libzip @ v1.8.0 (static) ----------------------------------------
RUN git clone "${LIBZIP_REPO}" libzip \
 && git -C libzip checkout "${LIBZIP_REF}" \
 && cd libzip; mkdir build; cd build; cmake -DBUILD_SHARED_LIBS=0 ..; make -j6; make install

# OCI labels — link the package to this repo on the GHCR package page.
LABEL org.opencontainers.image.source="https://github.com/dragoshont/altserver-stack" \
      org.opencontainers.image.title="altserver-builder-alpine-amd64" \
      org.opencontainers.image.description="Vendored AltServer-Linux build toolchain (Alpine 3.15 + Boost/corecrypto/cpprestsdk@v2.10.18/libzip@v1.8.0 static). Fork of NyaMisty/AltServer-Linux//buildenv to sever the dead upstream." \
      org.opencontainers.image.licenses="AGPL-3.0"
