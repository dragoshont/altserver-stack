# altserver-stack

A **self-contained, reproducible build chain** for [AltServer-Linux](https://github.com/NyaMisty/AltServer-Linux)
that produces **iOS 17+/26-valid signatures** — packaged as ready-to-run GHCR
container images.

This repo exists because the upstream AltServer-Linux ecosystem is effectively
abandoned (last release **v0.0.5, April 2022**) and its build chain quietly rots:
the bundled signer no longer satisfies modern AMFI, and the prebuilt toolchain
image depends on a third-party account that can vanish. `altserver-stack`
re-homes the **entire** chain — sources, build toolchain, and the signer fix —
under one maintained repo so it keeps working as Apple moves.

> [!IMPORTANT]
> **Personal/educational use.** This tool automates Apple-Developer-account
> sideloading with **your own** Apple ID. It is not affiliated with or endorsed
> by Apple. No warranty. It does **not** bundle Apple credentials or Apple's
> corecrypto source in any published image — corecrypto is fetched at build time
> from Apple's own server. Respect Apple's Developer Program terms and your local
> law. See [Credentials & safety](#credentials--safety).

---

## What you get

Two images on GitHub Container Registry:

| Image | What it is |
| --- | --- |
| `ghcr.io/dragoshont/altserver-linux` | **The engine.** `AltServer` + patched `zsign`, fully-static (musl) binaries. Run it directly or extract the binaries onto a host. |
| `ghcr.io/dragoshont/altserver-builder-alpine-amd64` | **The build toolchain.** Alpine 3.15 + Boost + static corecrypto/cpprestsdk/libzip. Only needed to *build* the engine. |

Both are `linux/amd64`.

## The two problems this solves

### 1. Code=85 — apps install but die at launch

Stock AltServer-Linux signs through its embedded
[AltSign-Linux](https://github.com/NyaMisty/AltSign-Linux), whose signer is a
4-year-old vendored `ldid` that emits a **dual SHA1+SHA256 CodeDirectory** and a
**legacy-DER entitlements** blob. Modern AMFI (iOS 17+/26, Apple Silicon)
rejects those:

- `codesign --verify` → `invalid signature` / `Authority=(unavailable)`
- apps **install but are killed at launch** (`Code=85`)

**Fix:** delegate the final codesign call to **zsign** with
[zhlynn/zsign#391](https://github.com/zhlynn/zsign/pull/391)
(`GLESign/zsign @ fe1750d`) — SHA256-only CodeDirectory + Apple-canonical DER
entitlements + correct `CS_EXECSEG`. AltServer's Apple-auth → certificate →
profile pipeline is left untouched; only the codesign call is swapped (see
[`apply-zsign-signer.py`](images/engine/apply-zsign-signer.py)). Verified
end-to-end on a physical **iPhone 16 Pro Max running iOS 26.5**.

### 2. Bus factor — the upstream chain can disappear

The original build depended on:
- `NyaMisty/AltServer-Linux` + `NyaMisty/AltSign-Linux` (dead repos), and
- a prebuilt `ghcr.io/nyamisty/altserver_builder_alpine_amd64` toolchain image.

If any of those go away, nobody can rebuild. `altserver-stack` severs all of it:
the three sources are hard-forked to `dragoshont/*` and pinned by SHA, the
AltSign submodule URL is repointed inside the AltServer fork, and the **build
toolchain is vendored** ([`images/builder/`](images/builder/Dockerfile)) and
built by our own CI. **Nothing in the build chain resolves to a deletable
upstream account.**

## corecrypto: the one true reproducibility hole

The only dependency that can't be pinned by a normal version handle is Apple's
**corecrypto**, fetched live from `developer.apple.com`. Apple silently revs it,
and the layout drifts. This repo's builder absorbs those breakages explicitly:

| Symptom | Cause | Fix in `images/builder/Dockerfile` |
| --- | --- | --- |
| zip extracts to `corecrypto-2024/` not `corecrypto/` | Apple renamed the top-level dir | normalize whatever dir ships into a stable `corecrypto/` by locating its `CMakeLists.txt` |
| `could not find scripts/code-coverage.cmake` | Apple references a StableCoder helper it doesn't ship (default-off `CODE_COVERAGE`) | `sed` out the include + `add/target_code_coverage()` calls |
| `Cannot find source file: corecrypto_static/ccrng_static.c` | generated sources list a path the zip doesn't ship (file is at tree root) | rewrite the path in `CoreCryptoSources.cmake` |
| `mode_t unknown` / `__memcpy_chk` undefined | `corecrypto_perf`/`_test` assume glibc/FORTIFY; we're on musl | drop those targets from `CMakeFiles/Makefile2` (they aren't needed) |

The fetched zip is **digest-guarded** (`CORECRYPTO_SHA256`): if Apple ships a
different artifact the build **fails loudly** instead of silently drifting. Bump
it deliberately via build-arg / workflow input when adopting a new drop.

## Pinned, reproducible deps

| Dep | Pin | Why |
| --- | --- | --- |
| cpprestsdk | `v2.10.18` (`122d0954…`) | last working release; EOL but stable |
| libzip | `v1.8.0` (`26ba5523…`) | matches the original toolchain |
| corecrypto | digest `b0f72ee1…` | no version handle; SHA256-guarded live fetch |
| zsign | `fe1750d` (PR #391) | the Code=85 fix |
| AltServer-Linux | `9282aff…` | master + AltSign submodule repoint |
| AltSign-Linux | `0daf107…` | the commit AltServer master pinned |

Our vendored builder reproduces the engine **bit-for-bit** identical to the
original prebuilt toolchain — proof the vendoring is faithful, not a rewrite.

## Use

```bash
# Extract the static binaries onto a host (bare-metal deploy):
docker run --rm -v /opt/altserver:/dest \
  ghcr.io/dragoshont/altserver-linux:latest-main extract

# Or run AltServer directly (containerised, alongside an anisette server):
docker run --network host -e ANISETTE_SERVER=http://127.0.0.1:6969 \
  -v /var/lib/altserver:/data \
  ghcr.io/dragoshont/altserver-linux:latest-main \
  AltServer -u <UDID> -a <appleid> -p <pass> /data/app.ipa
```

`ALTSIGN_ZSIGN=/usr/local/bin/zsign` is baked in so AltServer's `system()` call
finds the patched signer. When extracting to a host, keep `zsign` next to
`AltServer` (or set `ALTSIGN_ZSIGN`) so it stays on `PATH`.

## Build

| Image | Source | Workflow |
| --- | --- | --- |
| builder | [`images/builder/Dockerfile`](images/builder/Dockerfile) | [`build-builder.yml`](.github/workflows/build-builder.yml) |
| engine | [`images/engine/Dockerfile`](images/engine/Dockerfile) | [`build-engine.yml`](.github/workflows/build-engine.yml) |

The builder rarely changes; the engine consumes `builder:latest-main` as its
`BUILDER_IMAGE`. After a builder rebuild, re-run the engine workflow to relink.

All pins are overridable build-args / `workflow_dispatch` inputs so you can test
a dependency bump without editing the Dockerfile.

## Credentials & safety

- **Never** bake an Apple ID / password into an image or commit it. Pass them at
  runtime; keep them host-side (a secrets manager / SOPS), never in a web tier.
- The published images contain **no Apple credentials and no Apple source** —
  corecrypto is downloaded from Apple at build time, not redistributed here.
- Free Apple Developer accounts cap sideloading (3 apps / 7-day cert / limited
  device registrations). A paid account ($99/yr) lifts most of these.

## License

[AGPL-3.0](LICENSE), matching the AltServer-Linux lineage. The forks retain
their own upstream licenses; zsign is under its own terms.

## Lineage

Born out of [`dragoshont/homelab`](https://github.com/dragoshont/homelab), where
the Code=85 fix and the corecrypto-drift fixes were first worked out, then
extracted here so the build chain can be consumed (and improved) independently.
