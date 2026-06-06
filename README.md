# altserver-stack

Ready-to-run, **iOS 17+/26-valid** [AltServer-Linux](https://github.com/NyaMisty/AltServer-Linux)
as GHCR container images — plus the full, reproducible build chain behind them.

This builds on NyaMisty's AltServer-Linux (which brought AltStore-style
sideloading to Linux) and modernises it on three fronts: a codesigning path
today's AMFI accepts, a **corecrypto-free** GrandSlam auth path (Apple's crypto
swapped for the clean-room, OpenSSL-based
[libgsa](https://github.com/dragoshont/libgsa)), and a fully self-hosted build
chain so the whole thing stays buildable as its dependencies move. As far as we
know it's the first AltServer-Linux build that fetches, links, and ships **zero
Apple source**. Full credit for the engine stays with the upstream authors — see
[Credits](#credits).

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
| `ghcr.io/dragoshont/altserver-builder-alpine-amd64` | **The build toolchain.** Alpine 3.15 + Boost + static libgsa/cpprestsdk/libzip. Only needed to *build* the engine. |

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

## libgsa: corecrypto is gone

The original build's one un-pinnable input was Apple's **corecrypto**, fetched
live from `developer.apple.com` under a no-redistribution license, with a layout
that silently drifted between Apple drops. AltServer-Linux only ever used
corecrypto for one thing: the **GrandSlam (Apple ID) SRP-6a + AES/HMAC/PBKDF2**
handshake in `AltSign-Linux/Sources/.../AppleAPI+Authentication.cpp`.

This stack replaces it outright with **[libgsa](https://github.com/dragoshont/libgsa)**,
a clean-room reimplementation of that exact crypto on **OpenSSL/LibreSSL**. Its
SRP-6a is validated **byte-for-byte** against the Apple GrandSlam variant via a
golden-vector oracle. The builder compiles `libgsa.a` from a pinned commit and
the engine links it (plus the LibreSSL `libssl`/`libcrypto` already on AltServer's
static link line) instead of `libcorecrypto_static.a`.

The result: **no Apple source is fetched, linked, or shipped**, the
reproducibility hole is closed, and every input is pinned by a normal git SHA.

## Pinned, reproducible deps

| Dep | Pin | Why |
| --- | --- | --- |
| cpprestsdk | `v2.10.18` (`122d0954…`) | last working release; EOL but stable |
| libzip | `v1.8.0` (`26ba5523…`) | matches the original toolchain |
| libgsa | `ebb2919…` | corecrypto-free GrandSlam crypto (OpenSSL/LibreSSL) |
| zsign | `fe1750d` (PR #391) | the Code=85 fix |
| AltServer-Linux | `970efba…` | master + AltSign repoint + libgsa link |
| AltSign-Linux | `9a0d70a…` | corecrypto → libgsa port |

## Build

| Image | Source | Workflow |
| --- | --- | --- |
| builder | [`images/builder/Dockerfile`](images/builder/Dockerfile) | [`build-builder.yml`](.github/workflows/build-builder.yml) |
| engine | [`images/engine/Dockerfile`](images/engine/Dockerfile) | [`build-engine.yml`](.github/workflows/build-engine.yml) |

The builder rarely changes; the engine consumes `builder:latest-main` as its
`BUILDER_IMAGE`. After a builder rebuild, re-run the engine workflow to relink.

### Build locally (fully clean-room, no Apple fetch)

The engine is **corecrypto-free** — its GrandSlam crypto is libgsa
(OpenSSL/LibreSSL), so the build never reaches `developer.apple.com` and ships no
Apple source. Build it yourself with nothing but Docker:

```bash
./build.sh        # builds altserver-builder-alpine-amd64:local + altserver-linux:local
docker run --rm -v "$PWD/out:/dest" altserver-linux:local extract
```

The builder clones and compiles `libgsa` from `LIBGSA_REF`, installs `libgsa.a`
+ headers, and the engine links them. No download gates, no license prompts, no
cache mounts.

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
  the GrandSlam auth crypto is libgsa (OpenSSL/LibreSSL), not Apple corecrypto.
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
Developer Program agreement (sign your own apps with your own Apple ID). With
corecrypto replaced by libgsa, **every component is open-source licensed** — there
is no longer any Apple-source dependency.

| Component | License | In the published image? |
| --- | --- | --- |
| AltServer-Linux (NyaMisty / AltStore lineage) | AGPL-3.0 | yes — binary |
| AltSign-Linux (NyaMisty / AltStore lineage) | AGPL-3.0 | yes — binary |
| libgsa (dragoshont) | MIT | static-linked |
| zsign (zhlynn, PR #391) | MIT | yes — binary |
| cpprestsdk (Microsoft) | MIT | static-linked |
| libzip (nih-at) | BSD-3-Clause | static-linked |
| Boost | BSL-1.0 | static-linked |

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
the Code=85 fix and the corecrypto→libgsa replacement were first worked out, then
extracted here so the build chain can be consumed — and improved — independently.
