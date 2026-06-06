# altserver-stack

Ready-to-run, **iOS 17+/26-valid** [AltServer-Linux](https://github.com/NyaMisty/AltServer-Linux)
as GHCR container images — plus the full, reproducible build chain behind them.

This builds on NyaMisty's AltServer-Linux (which brought AltStore-style
sideloading to Linux). It adds the two things current iOS needs: a codesigning
path that today's AMFI accepts, and a self-hosted build chain so the whole thing
stays buildable as its dependencies move. Full credit for the engine stays with
the upstream authors — see [Credits](#credits).

---

## Quick start

You almost certainly want the prebuilt **engine** image — no need to build
anything.

```bash
# Option A — extract the static binaries onto a host (bare-metal deploy):
docker run --rm -v /opt/altserver:/dest \
  ghcr.io/dragoshont/altserver-linux:latest-main extract
# -> drops AltServer + the patched zsign into /opt/altserver

# Option B — run AltServer directly (containerised, alongside an anisette server):
docker run --network host -e ANISETTE_SERVER=http://127.0.0.1:6969 \
  -v /var/lib/altserver:/data \
  ghcr.io/dragoshont/altserver-linux:latest-main \
  AltServer -u <UDID> -a <your-apple-id> -p <password> /data/app.ipa
```

`ALTSIGN_ZSIGN=/usr/local/bin/zsign` is baked in so AltServer's `system()` call
finds the patched signer. When extracting to a host, keep `zsign` next to
`AltServer` (or set `ALTSIGN_ZSIGN`) so it stays on `PATH`.

> Pass your Apple ID at runtime — never bake it into an image. See
> [Credentials & safety](#credentials--safety).

---

## What you get

Two images on GitHub Container Registry:

| Image | What it is |
| --- | --- |
| `ghcr.io/dragoshont/altserver-linux` | **The engine.** `AltServer` + patched `zsign`, fully-static (musl) binaries. Run it directly or extract the binaries onto a host. |
| `ghcr.io/dragoshont/altserver-builder-alpine-amd64` | **The build toolchain.** Alpine 3.15 + Boost + static corecrypto/cpprestsdk/libzip. Only needed to *build* the engine. |

Both are `linux/amd64`.

## Why this exists

AltServer-Linux had its last tagged release (**v0.0.5**) in **April 2022**. It
still does its job, but iOS has tightened since, and the original build chain
leaned on a few moving parts that are awkward to depend on long-term. This repo
addresses both while keeping NyaMisty's engine at its core.

### 1. Code=85 — apps install but die at launch on modern iOS

Stock AltServer-Linux signs through its embedded
[AltSign-Linux](https://github.com/NyaMisty/AltSign-Linux), whose signer is an
older vendored `ldid` that emits a **dual SHA1+SHA256 CodeDirectory** and a
**legacy-DER entitlements** blob. That shape was fine for its era, but modern
AMFI (iOS 17+/26, Apple Silicon) rejects it:

- `codesign --verify` → `invalid signature` / `Authority=(unavailable)`
- apps **install but are killed at launch** (`Code=85`)

**Fix:** delegate the final codesign call to **zsign** with
[zhlynn/zsign#391](https://github.com/zhlynn/zsign/pull/391)
(`GLESign/zsign @ fe1750d`) — SHA256-only CodeDirectory + Apple-canonical DER
entitlements + correct `CS_EXECSEG`. AltServer's Apple-auth → certificate →
profile pipeline is left untouched; only the codesign call is swapped (see
[`apply-zsign-signer.py`](images/engine/apply-zsign-signer.py)). Verified
end-to-end on a physical **iPhone 16 Pro Max running iOS 26.5**.

### 2. A build chain that stays buildable

The original build pulls the upstream sources plus a prebuilt
`altserver_builder_alpine_amd64` toolchain image hosted under a single
maintainer's account — a perfectly reasonable setup, but for something we want
to keep rebuilding years from now we wanted every input under our own control.
So `altserver-stack` hard-forks the three sources to `dragoshont/*` and pins
them by SHA, repoints the AltSign submodule URL inside the AltServer fork, and
**vendors the build toolchain** ([`images/builder/`](images/builder/Dockerfile))
into our own CI. The result reproduces the engine **bit-for-bit** identical to a
build against the original toolchain — evidence the vendoring is a faithful copy,
not a rewrite.

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

- This tool sideloads with **your own** Apple ID, the same way AltStore /
  AltServer do. It is not affiliated with or endorsed by Apple — follow the
  [Apple Developer Program](https://developer.apple.com/support/terms/) terms for
  your account.
- **Never** bake an Apple ID / password into an image or commit one. Pass them at
  runtime and keep them host-side (a secrets manager / SOPS), never in a web tier.
- The published images contain **no Apple credentials and no Apple source code** —
  corecrypto is fetched from Apple at build time and is *not* redistributed here.
- Free Apple Developer accounts cap sideloading (3 apps / 7-day certificate /
  limited device registrations). A paid account lifts most of these limits.

## License

This repository's own files (Dockerfiles, workflows, scripts) and the resulting
engine image are distributed under **[AGPL-3.0](LICENSE)**. That isn't a choice
of convenience — AltServer-Linux and the AltStore/AltSign code it builds on are
themselves AGPL-3.0, the strongest copyleft, which propagates to anything derived
from them.

Each upstream license below was checked against its source. None of the *code*
licenses (AGPL / MIT / BSD / BSL) restrict commercial use — so this project does
not either. The practical limits on *how you sideload* come from Apple's
Developer Program agreement (sign your own apps with your own Apple ID), and the
one genuinely restrictive input is Apple's corecrypto — see the note below.

| Component | License | In the published image? |
| --- | --- | --- |
| AltServer-Linux (NyaMisty / AltStore lineage) | AGPL-3.0 | yes — binary |
| AltSign-Linux (NyaMisty / AltStore lineage) | AGPL-3.0 | yes — binary |
| zsign (zhlynn, PR #391) | MIT | yes — binary |
| cpprestsdk (Microsoft) | MIT | static-linked |
| libzip (nih-at) | BSD-3-Clause | static-linked |
| Boost | BSL-1.0 | static-linked |
| Apple corecrypto | **corecrypto Internal Use License** (not redistributable) | **no source** — fetched from Apple at build time |

**About Apple corecrypto.** corecrypto ships under Apple's *corecrypto Internal
Use License Agreement* (rev EA1833), **not** APSL or any open-source license. It
grants a 90-day licence to compile and run corecrypto **internally**, on machines
you own or control, **for the sole purpose of verifying its security
characteristics**, and **forbids redistribution** of the software or any portion
of it. This repo therefore never commits or republishes corecrypto source — the
builder downloads it straight from `developer.apple.com` at build time, and you
accept Apple's terms when you build. The engine statically links corecrypto,
exactly as upstream AltServer-Linux does; redistributing the *built* binary is
your responsibility under Apple's terms, so the safe default is to build/extract
for your own use rather than republish the engine image.

If you redistribute the AGPL parts (this repo + the pinned forks), the usual
AGPL-3.0 source-availability obligations apply to your recipients.

## Credits

- **[AltStore / AltSign](https://altstore.io)** by Riley Testut and contributors —
  the upstream signing and sideloading project this whole lineage descends from.
- **[AltServer-Linux](https://github.com/NyaMisty/AltServer-Linux)** and
  **[AltSign-Linux](https://github.com/NyaMisty/AltSign-Linux)** by **NyaMisty** —
  the Linux port that makes this possible. This repo only re-homes and modernises
  their work.
- **[zsign](https://github.com/zhlynn/zsign)** by zhlynn, and the
  [#391](https://github.com/zhlynn/zsign/pull/391) SHA256-CodeDirectory work that
  keeps signatures valid on current iOS.

## Lineage

Born out of [`dragoshont/homelab`](https://github.com/dragoshont/homelab), where
the Code=85 fix and the corecrypto-drift handling were first worked out, then
extracted here so the build chain can be consumed — and improved — independently.
