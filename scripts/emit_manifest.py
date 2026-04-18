#!/usr/bin/env python3
"""Generate intersect_ort_bundles_manifest.json for the INTERSECT plugin.

The plugin (tuckers-sampler/src/audio/StemSeparation.cpp :: applyOrtManifestEntryToCatalogEntry)
reads these fields per bundle:
  bundle_id      -- kebab-case, must match the built-in catalog's directoryName
  download_url   -- GitHub release asset URL
  download_bytes -- integer, used for progress + size display
  library_file   -- the shared-library filename inside lib/

`sha256` is emitted for transparency / future use, but the plugin does not currently verify it.

Two modes:
  full     -- enumerate all zips in --input-dir, produce complete manifest
  append   -- take an existing manifest, add/replace the MIGraphX entry, write back

Stdlib-only (hashlib, json, argparse, pathlib).
"""
from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path

REPO = "tucktuckg00se/intersect-ort-providers"

# Archive name -> (bundle_id, library_file). bundle_id matches the plugin catalog's directoryName.
BUNDLE_TABLE: dict[str, tuple[str, str]] = {
    "onnxruntime-win-x64-directml.zip":   ("win-x64-directml",   "onnxruntime.dll"),
    "onnxruntime-win-x64-cpu.zip":        ("win-x64-cpu",        "onnxruntime.dll"),
    "onnxruntime-linux-x64-cpu.zip":      ("linux-x64-cpu",      "libonnxruntime.so"),
    "onnxruntime-linux-x64-cuda12.zip":   ("linux-x64-cuda12",   "libonnxruntime.so"),
    "onnxruntime-linux-x64-cuda13.zip":   ("linux-x64-cuda13",   "libonnxruntime.so"),
    "onnxruntime-linux-x64-migraphx.zip": ("linux-x64-migraphx", "libonnxruntime.so"),
    "onnxruntime-macos-arm64.zip":        ("macos-arm64",        "libonnxruntime.dylib"),
}


def sha256_of(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def build_entry(zip_path: Path, ort_version: str) -> dict:
    archive = zip_path.name
    if archive not in BUNDLE_TABLE:
        raise SystemExit(f"unknown archive name: {archive}")
    bundle_id, library_file = BUNDLE_TABLE[archive]
    return {
        "bundle_id":      bundle_id,
        "download_url":   f"https://github.com/{REPO}/releases/download/ort-{ort_version}/{archive}",
        "download_bytes": zip_path.stat().st_size,
        "library_file":   library_file,
        "sha256":         sha256_of(zip_path),
    }


def cmd_full(args: argparse.Namespace) -> None:
    input_dir = Path(args.input_dir)
    zips = sorted(input_dir.glob("onnxruntime-*.zip"))
    if not zips:
        raise SystemExit(f"no zips found under {input_dir}")
    bundles = [build_entry(z, args.ort_version) for z in zips]
    manifest = {"ort_version": args.ort_version, "bundles": bundles}
    Path(args.output).write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"wrote {args.output} ({len(bundles)} bundles)", file=sys.stderr)


def cmd_append(args: argparse.Namespace) -> None:
    existing_path = Path(args.manifest)
    if not existing_path.is_file():
        raise SystemExit(f"manifest not found: {existing_path}")
    manifest = json.loads(existing_path.read_text())
    new_entry = build_entry(Path(args.bundle), args.ort_version)
    bundles = [b for b in manifest.get("bundles", []) if b.get("bundle_id") != new_entry["bundle_id"]]
    bundles.append(new_entry)
    bundles.sort(key=lambda b: b["bundle_id"])
    manifest["bundles"] = bundles
    manifest["ort_version"] = args.ort_version
    Path(args.output).write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"wrote {args.output} with {new_entry['bundle_id']} appended", file=sys.stderr)


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__)
    sub = p.add_subparsers(dest="mode", required=True)

    full = sub.add_parser("full", help="generate manifest from all zips in a directory")
    full.add_argument("--ort-version", required=True)
    full.add_argument("--input-dir", required=True)
    full.add_argument("--output", default="intersect_ort_bundles_manifest.json")
    full.set_defaults(func=cmd_full)

    app = sub.add_parser("append", help="merge/replace one bundle entry into an existing manifest")
    app.add_argument("--ort-version", required=True)
    app.add_argument("--manifest", required=True, help="path to existing manifest to update")
    app.add_argument("--bundle", required=True, help="path to the bundle zip to add/replace")
    app.add_argument("--output", default="intersect_ort_bundles_manifest.json")
    app.set_defaults(func=cmd_append)

    args = p.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
