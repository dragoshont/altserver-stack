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
# Upstream cloned cpprestsdk + libzip at HEAD-of-the-day and pulled Apple
# corecrypto live, so two builds months apart could differ. We pin both git deps
# to the release SHAs that were current when the upstream toolchain last worked
# (~Apr 2022): cpprestsdk v2.10.18 and libzip v1.8.0. corecrypto is gone entirely
# — the GrandSlam crypto is now libgsa, pinned to LIBGSA_REF, so the build is
# fully reproducible and never reaches developer.apple.com. Bump any pin via
# --build-arg.
#
# What it provides
# ----------------
# Alpine 3.15 + the compilers (g++, clang, cmake, ninja, make), Boost (static),
# and three from-source static libraries that AltServer-Linux links against:
#   * libgsa (LIBGSA_REF, corecrypto-free OpenSSL/LibreSSL GrandSlam crypto)
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
# libgsa — clean-room, corecrypto-free reimplementation of the GrandSlam SRP +
# AES/HMAC/PBKDF2 crypto AltServer's signer needs, built on OpenSSL/LibreSSL.
# Pin the validated commit; bump LIBGSA_REF to adopt a newer drop.
ARG LIBGSA_REPO=https://github.com/dragoshont/libgsa
ARG LIBGSA_REF=ebb29197872c4a3a130e1400d1a6451baee0424a

RUN  apk add zsh git curl wget g++ clang boost-static ninja boost-dev cmake make sudo bash vim libressl-dev util-linux-dev zlib-dev zlib-static

RUN mkdir /buildenv

WORKDIR /buildenv

# --- libgsa (corecrypto-free GrandSlam crypto, OpenSSL/LibreSSL) ------------
# Replaces Apple corecrypto outright. libgsa's SRP-6a is proven byte-for-byte
# against the Apple GrandSlam variant; the engine links libgsa.a + the LibreSSL
# libssl/libcrypto already on AltServer's static link line, instead of
# libcorecrypto_static.a. Nothing is fetched from Apple any more, so the build
# no longer needs the corecrypto download/cache/BYO machinery or its SHA guard.
RUN git clone "${LIBGSA_REPO}" libgsa \
 && git -C libgsa checkout "${LIBGSA_REF}" \
 && cmake -S libgsa -B libgsa/build -DCMAKE_BUILD_TYPE=Release -DGSA_BUILD_TESTS=OFF \
 && cmake --build libgsa/build -j"$(nproc)" \
 && install -m 0644 libgsa/build/libgsa.a /usr/local/lib/libgsa.a \
 && cp -a libgsa/include/gsa /usr/local/include/gsa \
 && echo "== libgsa installed ==" && ls -l /usr/local/lib/libgsa.a /usr/local/include/gsa

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
      org.opencontainers.image.description="Vendored AltServer-Linux build toolchain (Alpine 3.15 + Boost/libgsa/cpprestsdk@v2.10.18/libzip@v1.8.0 static). Fork of NyaMisty/AltServer-Linux//buildenv to sever the dead upstream; corecrypto replaced by libgsa (OpenSSL/LibreSSL)." \
      org.opencontainers.image.licenses="AGPL-3.0"
