# syntax=docker/dockerfile:1
#
# Rebuilds AltServer-Linux with its signing step delegated to a patched zsign so
# that signatures are valid on iOS 17+/26 (Apple Silicon AMFI).
#
# Vendoring
# ---------
# The upstream engine (NyaMisty/AltServer-Linux + NyaMisty/AltSign-Linux) is dead
# (last release v0.0.5, Apr 2022). To sever the bus-factor risk we hard-fork all
# three sources into dragoshont/* and pin SHAs here; the AltSign submodule inside
# dragoshont/AltServer-Linux is repointed at dragoshont/AltSign-Linux too, so no
# build path resolves to a deletable upstream account. zsign tracks GLESign via
# the dragoshont/zsign fork at the same verified commit. The build toolchain
# (BUILDER_IMAGE, formerly ghcr.io/nyamisty/altserver_builder_alpine_amd64) is
# vendored too — see ../builder/ — so NOTHING in the build chain is
# NyaMisty-owned anymore.
#
# Background
# ----------
# AltServer-Linux signs through its embedded AltSign-Linux, whose signer is a
# 4-year-old vendored `ldid` that emits SHA1+legacy-DER signatures. Modern AMFI
# rejects those: apps install but are killed at launch (Code=85). The proven fix
# is zsign with zhlynn/zsign PR #391 (GLESign/zsign @ fe1750d): SHA256-only
# CodeDirectory + Apple-canonical DER entitlements. We verified that exact zsign
# build end-to-end on a physical iPhone 16 Pro Max running iOS 26.5.
#
# apply-zsign-signer.py rewrites AltSign-Linux/Signer.cpp's `ldid::Sign(...)`
# call into a `zsign -k <p12> -p "" -m <embedded.mobileprovision> <app>` call.
# Both binaries are built fully static (musl) so they run bare on the Ubuntu host
# AND inside this Alpine image.

# BUILDER_IMAGE is the AltServer-Linux build toolchain (Alpine 3.15 + Boost +
# static libgsa/cpprestsdk/libzip). Vendored from NyaMisty/AltServer-Linux//
# buildenv into images/builder/ and published by the build-builder workflow, so
# the engine build no longer depends on any NyaMisty-owned artifact. Override to
# nyamisty's image only for emergency builds.
ARG BUILDER_IMAGE=ghcr.io/dragoshont/altserver-builder-alpine-amd64:latest-main

# ---------------------------------------------------------------------------
# Stage 1: patched zsign (the proven iOS-26-valid signer)
# ---------------------------------------------------------------------------
# zsign is standalone — it only needs OpenSSL 3.x + a C++ compiler + its own
# bundled zlib/minizip. It does NOT need the heavy AltServer builder deps, and
# it CANNOT build on the NyaMisty builder image: that image ships LibreSSL (and
# Alpine 3.15's openssl is 1.1.1), neither of which has <openssl/provider.h> that
# zsign's certcheck.cpp requires. Build it on stock Alpine 3.20 (OpenSSL 3.3),
# fully static (musl) so the binary runs bare on the Ubuntu host AND in runtime.
FROM alpine:3.20 AS zsign-build

# dragoshont/zsign is our fork of GLESign/zsign; fe1750d is the PR #391 commit we
# verified on iOS 26.5 and exists unchanged in the fork.
ARG ZSIGN_REPO=https://github.com/dragoshont/zsign
ARG ZSIGN_REF=fe1750d5d4a173b060217d38affd1b196ce1c0ba

RUN apk add --no-cache git make g++ openssl-dev openssl-libs-static

WORKDIR /src
RUN git clone "${ZSIGN_REPO}" zsign \
 && git -C zsign checkout "${ZSIGN_REF}"

# Alpine 3.20's gcc 13 + musl no longer transitively pull <ctime>, so zsign's
# common/json.h fails with "'time_t' does not name a type" (the macOS/clang build
# masks this). Force-include <ctime> at the top of json.h before compiling.
RUN sed -i '1i #include <ctime>' /src/zsign/src/common/json.h

# zsign's build/linux Makefile links via OPENSSL_LIB (= pkg-config --libs
# openssl) and has no LDFLAGS hook, so we inject the fully-static link through
# OPENSSL_LIB itself: -static + the OpenSSL static archives (libssl before
# libcrypto). zsign bundles its own zlib + minizip (src/third-party) so no zlib
# package is needed.
RUN cd zsign \
 && make -C build/linux -j"$(nproc)" \
        OPENSSL_LIB="-static -l:libssl.a -l:libcrypto.a -static-libstdc++ -static-libgcc" \
 && bin="$(find . -type f -name zsign -perm -u+x | head -n1)" \
 && test -n "$bin" \
 && install -m 0755 "$bin" /usr/local/bin/zsign \
 && echo "== zsign linkage ==" \
 && ( ldd /usr/local/bin/zsign 2>&1 || true ) \
 && if ldd /usr/local/bin/zsign 2>&1 | grep -q '=>'; then \
        echo "ERROR: zsign is dynamically linked (won't run bare on the Ubuntu host)"; exit 1; \
    fi \
 && /usr/local/bin/zsign -v || true

# ---------------------------------------------------------------------------
# Stage 2: AltServer-Linux with the signer patched to call zsign
# ---------------------------------------------------------------------------
FROM ${BUILDER_IMAGE} AS altserver-build

# dragoshont/AltServer-Linux is our fork of NyaMisty/AltServer-Linux. The pinned
# SHA is master + the .gitmodules repoint that swaps the AltSign submodule URL to
# dragoshont/AltSign-Linux (now the libgsa port), so `submodule update` never
# touches NyaMisty and the signer's GrandSlam auth links libgsa, not corecrypto.
ARG ALTSERVER_REPO=https://github.com/dragoshont/AltServer-Linux
# be6f328: anisette server overridable via ALTSERVER_ANISETTE_SERVER (point at
# the self-hosted anisette-v3-server flat GET /; armconverter.com default when
# unset). Frees the signer from the flaky public armconverter.com anisette.
ARG ALTSERVER_REF=be6f32809e85a7820ff893e28d512bb31d8ce5c6

RUN apk add --no-cache git make g++ python3

WORKDIR /src
RUN git clone --recursive "${ALTSERVER_REPO}" altserver \
 && git -C altserver checkout "${ALTSERVER_REF}" \
 && git -C altserver submodule sync --recursive \
 && git -C altserver submodule update --init --recursive

COPY apply-zsign-signer.py /src/apply-zsign-signer.py
RUN cd altserver \
 && python3 /src/apply-zsign-signer.py libraries/AltSign/Signer.cpp

RUN cd altserver \
 && make NO_USBMUXD_STUB=1 NO_UPNP_STUB=1 -j"$(nproc)" \
 && bin="$(find . -type f -name 'AltServer*' -perm -u+x \
        ! -name '*.py' ! -name '*.sh' ! -name '*.sln' ! -name '*.vcxproj*' \
        -exec sh -c 'head -c4 "$1" | grep -q ELF && echo "$1"' _ {} \; \
        | head -n1)" \
 && test -n "$bin" || { echo "ERROR: no AltServer ELF binary produced by the build"; exit 1; } \
 && echo "== picked AltServer binary: $bin ==" \
 && ( file "$bin" 2>/dev/null || true ) \
 && install -m 0755 "$bin" /usr/local/bin/AltServer \
 && echo "== AltServer linkage ==" \
 && ( ldd /usr/local/bin/AltServer 2>&1 || true ) \
 && head -c4 /usr/local/bin/AltServer | grep -q ELF \
        || { echo "ERROR: installed AltServer is not an ELF binary"; exit 1; }

# ---------------------------------------------------------------------------
# Stage 3: runtime / delivery image
# ---------------------------------------------------------------------------
FROM alpine:3.20

# OCI labels — GitHub renders these on the public GHCR package page (links the
# package to this repo and shows the description / why we rebuilt AltServer).
LABEL org.opencontainers.image.title="altserver-linux (iOS-26-valid signer)" \
      org.opencontainers.image.description="AltServer-Linux (NyaMisty fork) rebuilt with its signing step delegated to a patched zsign (zhlynn/zsign#391, GLESign/zsign@fe1750d). Stock AltServer-Linux signs through a 4-year-old vendored ldid that emits SHA1+legacy-DER signatures modern AMFI rejects on iOS 17+/26 (apps install but die at launch, Code=85). This image swaps only the final codesign call for SHA256-only + Apple-canonical DER entitlements, verified end-to-end on a physical iPhone 16 Pro Max running iOS 26.5. Ships AltServer + zsign as fully-static (musl) binaries." \
      org.opencontainers.image.source="https://github.com/dragoshont/altserver-stack" \
      org.opencontainers.image.documentation="https://github.com/dragoshont/altserver-stack/blob/main/README.md" \
      org.opencontainers.image.licenses="AGPL-3.0" \
      org.opencontainers.image.vendor="dragoshont/altserver-stack"

RUN apk add --no-cache libstdc++ openssl ca-certificates

COPY --from=altserver-build /usr/local/bin/AltServer /usr/local/bin/AltServer
COPY --from=zsign-build     /usr/local/bin/zsign     /usr/local/bin/zsign

# zsign must be discoverable by AltServer's system() call.
ENV ALTSIGN_ZSIGN=/usr/local/bin/zsign
ENV PATH="/usr/local/bin:${PATH}"

# Self-test layer: confirm both binaries are real ELF executables. zsign must
# report a version; AltServer must be an ELF (it exits non-zero on --help with no
# device, which is fine — we only assert it's a runnable binary, not a script).
RUN head -c4 /usr/local/bin/AltServer | grep -q ELF \
        || { echo "ERROR: AltServer is not an ELF binary"; exit 1; } \
 && head -c4 /usr/local/bin/zsign | grep -q ELF \
        || { echo "ERROR: zsign is not an ELF binary"; exit 1; } \
 && /usr/local/bin/zsign -v \
 && size_as=$(wc -c < /usr/local/bin/AltServer) \
 && test "$size_as" -gt 1000000 \
        || { echo "ERROR: AltServer suspiciously small ($size_as bytes)"; exit 1; } \
 && echo "self-test OK: AltServer ${size_as}B ELF, zsign present"

# Two ways to consume this image:
#   1. Run AltServer directly (containerised, like anisette):
#        docker run --network host -e ANISETTE_SERVER=... <img> \
#          AltServer -u <UDID> -a <appleid> -p <pass> /data/app.ipa
#   2. Extract the static binaries onto the host (current bare-metal deploy):
#        docker run --rm -v /opt/altserver:/dest <img> extract
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 0755 /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["AltServer", "--help"]
