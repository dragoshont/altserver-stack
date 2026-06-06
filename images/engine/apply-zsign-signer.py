#!/usr/bin/env python3
"""Patch AltSign-Linux's Signer.cpp to delegate the final codesign to zsign.

Why
---
AltServer-Linux signs IPAs through its embedded copy of AltSign-Linux, whose
signer is a 4-year-old vendored `ldid` (last touched "Fix ipa crashing for iOS
15.1+"). That ldid emits a dual SHA1+SHA256 CodeDirectory and a legacy-DER
entitlements blob. On iOS 17+/26 AMFI rejects those signatures, so AltServer-
signed apps install but are killed at launch (Code=85), and `codesign --verify`
on Apple Silicon reports `invalid signature` / `Authority=(unavailable)`.

The fix that is *proven* to produce iOS-26-valid signatures is zsign with
zhlynn/zsign PR #391 (GLESign/zsign @ fe1750d): SHA256-only CodeDirectory +
Apple-canonical DER entitlements + correct CS_EXECSEG flag handling. We verified
that exact binary end-to-end on a physical iPhone 16 Pro Max running iOS 26.5.

Rather than re-porting those changes into the ancient ldid, we keep AltServer's
working Apple-auth / certificate / provisioning-profile pipeline intact and only
replace the single signing step: instead of calling `ldid::Sign(...)` we invoke
the bundled patched `zsign` against the prepared .app bundle. AltSign has already
written each target's `embedded.mobileprovision` into the bundle and we hand the
re-encoded p12 (cert chain + key, empty password) to zsign.

This script is intentionally marker-based (not a context diff) so it survives
minor upstream whitespace changes.
"""
import pathlib
import sys

MARKER_START = "ldid::DiskFolder appBundle(app.path());"
MARKER_END = "}));"

REPLACEMENT = r"""std::string key = CertificatesContent(this->certificate());

        // ---- iOS 17+/26 fix: delegate codesign to patched zsign --------------
        // The vendored ldid emits SHA1+legacy-DER signatures that modern AMFI
        // rejects (app installs but is killed at launch with Code=85). zsign
        // (GLESign/zsign @ fe1750d, PR zhlynn/zsign#391) emits a SHA256-only
        // CodeDirectory + Apple-canonical DER entitlements that iOS 26 accepts.
        // AltSign has already written embedded.mobileprovision into each target
        // and `key` holds the cert chain + private key as a passwordless p12.
        {
            fs::path p12Path = fs::temp_directory_path() / (make_uuid() + ".p12");
            {
                std::ofstream p12out(p12Path.string(), std::ios::out | std::ios::binary);
                p12out.write(key.data(), (std::streamsize)key.size());
                p12out.close();
            }

            fs::path provPath = fs::path(app.path()).append("embedded.mobileprovision");

            std::string zsignBin = "zsign";
            const char* envBin = getenv("ALTSIGN_ZSIGN");
            if (envBin != nullptr && strlen(envBin) > 0)
            {
                zsignBin = envBin;
            }

            std::string cmd = zsignBin
                + " -k \"" + p12Path.string() + "\""
                + " -p \"\""
                + " -m \"" + provPath.string() + "\""
                + " \"" + app.path() + "\"";

            odslog("Signing app " << app.path() << " using zsign: " << cmd);
            int rc = std::system(cmd.c_str());

            std::error_code _rmEc;
            fs::remove(p12Path, _rmEc);

            if (rc != 0)
            {
                odslog("zsign failed (rc=" << rc << ") for " << app.path());
                throw SignError(SignErrorCode::InvalidCertificate);
            }
        }
"""

INCLUDE_ANCHOR = '#include "Archiver.hpp"'
INCLUDE_INJECT = '#include "Archiver.hpp"\n\n#include <cstdlib>   // std::system, getenv\n#include <cstring>   // strlen\n#include <system_error>'


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: apply-zsign-signer.py <path/to/Signer.cpp>", file=sys.stderr)
        return 2

    path = pathlib.Path(sys.argv[1])
    src = path.read_text()

    if "using zsign" in src:
        print(f"[apply-zsign-signer] already patched: {path}")
        return 0

    start = src.find(MARKER_START)
    if start == -1:
        print(f"[apply-zsign-signer] ERROR: start marker not found in {path}", file=sys.stderr)
        return 1

    end = src.find(MARKER_END, start)
    if end == -1:
        print(f"[apply-zsign-signer] ERROR: end marker not found in {path}", file=sys.stderr)
        return 1
    end += len(MARKER_END)

    patched = src[:start] + REPLACEMENT.strip() + src[end:]

    # Ensure the headers we rely on are present.
    if "<cstdlib>" not in patched:
        if INCLUDE_ANCHOR not in patched:
            print(f"[apply-zsign-signer] ERROR: include anchor not found in {path}", file=sys.stderr)
            return 1
        patched = patched.replace(INCLUDE_ANCHOR, INCLUDE_INJECT, 1)

    path.write_text(patched)
    print(f"[apply-zsign-signer] patched {path}: ldid::Sign -> zsign delegation")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
