#!/usr/bin/env python3
"""Shuttle auto-update: generate and sign shuttle-update.json.

Called by the release workflow .github/workflows/shareme_release.yml. The app side of the format and its
verification are in app/lib/util/shareme_update/update_manifest.dart; change both together.

    python3 shuttle_update_manifest.py --version 2026.11.20 --build 2275 \
        --base-url https://github.com/JackWorld99/shuttle/releases/download/v2026.11.22-2301/ \
        --file windows-x64=Shuttle-Setup-2026.11.20.exe --file android-arm64=Shuttle-2026.11.20.apk \
        --notes-zh "…" --notes-en "…" --key update-key.pem \
        --trusted-keys app/lib/util/shareme_update/update_config.dart --out shuttle-update.json

Signature: Ed25519 (RFC 8032) over the raw manifest bytes, made with OpenSSL 3's `pkeyutl -sign -rawin`.
The private key is only read from --key and never printed.
If --trusted-keys is given, the public key matching --key must appear in that file (the app only trusts the
keys listed there); otherwise the script fails without writing any output.
"""
import argparse
import base64
import datetime
import hashlib
import json
import os
import subprocess
import sys
import tempfile

FORMAT = "shuttle-update-1"
SCHEMA = 1


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def openssl(*args):
    subprocess.run(["openssl", *args], check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)


def main():
    # The Windows console is not UTF-8 by default; printing non-ASCII text (such as file paths) could fail
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--version", required=True)
    ap.add_argument("--build", required=True, type=int)
    ap.add_argument("--base-url", required=True, help="download URL prefix of the release, ending in /")
    ap.add_argument("--file", action="append", required=True, help="platform=path, e.g. windows-x64=Shuttle-Setup-x.exe")
    ap.add_argument("--notes-zh", default="")
    ap.add_argument("--notes-en", default="")
    ap.add_argument("--date", help="ISO 8601; defaults to now (UTC)")
    ap.add_argument("--key", required=True, help="Ed25519 private key (PEM)")
    ap.add_argument("--trusted-keys", help="file in the app that lists the trusted public keys (update_config.dart)")
    ap.add_argument("--out", required=True)
    a = ap.parse_args()

    if not a.base_url.startswith("https://") or not a.base_url.endswith("/"):
        sys.exit("--base-url must start with https:// and end with /")

    files = {}
    for spec in a.file:
        platform, _, path = spec.partition("=")
        if not platform or not path or not os.path.isfile(path):
            sys.exit(f"Invalid --file: {spec}")
        files[platform] = {
            "url": a.base_url + os.path.basename(path),
            "size": os.path.getsize(path),
            "sha256": sha256_file(path),
        }

    notes = {k: v for k, v in (("zh", a.notes_zh.strip()), ("en", a.notes_en.strip())) if v}
    date = a.date or datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    manifest = {"schema": SCHEMA, "version": a.version, "build": a.build, "date": date, "notes": notes, "files": files}
    payload = json.dumps(manifest, ensure_ascii=False, separators=(",", ":")).encode("utf-8")

    with tempfile.TemporaryDirectory(dir=os.path.dirname(os.path.abspath(a.out))) as tmp:
        payload_path = os.path.join(tmp, "payload.json")
        sig_path = os.path.join(tmp, "payload.sig")
        pub_der = os.path.join(tmp, "pub.der")
        pub_pem = os.path.join(tmp, "pub.pem")
        with open(payload_path, "wb") as f:
            f.write(payload)
        openssl("pkeyutl", "-sign", "-inkey", a.key, "-rawin", "-in", payload_path, "-out", sig_path)
        openssl("pkey", "-in", a.key, "-pubout", "-outform", "DER", "-out", pub_der)
        openssl("pkey", "-in", a.key, "-pubout", "-out", pub_pem)
        # Verify right away with the public key to make sure OpenSSL produced a standard Ed25519 signature
        openssl("pkeyutl", "-verify", "-pubin", "-inkey", pub_pem, "-rawin", "-in", payload_path, "-sigfile", sig_path)
        with open(sig_path, "rb") as f:
            signature = f.read()
        with open(pub_der, "rb") as f:
            der = f.read()

    # The DER (SubjectPublicKeyInfo) of an Ed25519 public key is a fixed 12-byte header + the 32-byte raw key
    if len(der) != 44 or len(signature) != 64:
        sys.exit("The private key is not an Ed25519 key")
    raw_pub = der[-32:]
    pub_b64 = base64.b64encode(raw_pub).decode()
    key_id = hashlib.sha256(raw_pub).hexdigest()[:16]

    if a.trusted_keys:
        with open(a.trusted_keys, encoding="utf-8") as f:
            if f"'{pub_b64}'" not in f.read():
                sys.exit(f"Public key {pub_b64} of the signing key is not in {a.trusted_keys}; the app would reject it.")

    envelope = {
        "format": FORMAT,
        "key": key_id,
        "payload": base64.b64encode(payload).decode(),
        "signature": base64.b64encode(signature).decode(),
    }
    with open(a.out, "w", encoding="utf-8", newline="\n") as f:
        json.dump(envelope, f, indent=2)
        f.write("\n")
    print(f"Wrote {a.out}: version {a.version} ({a.build}), key ID {key_id}, files {', '.join(files)}")


if __name__ == "__main__":
    main()
