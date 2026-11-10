#!/usr/bin/env python3
"""Generate intersect_media_tools_manifest.json for INTERSECT's URL import.

The plugin finds the newest media-* release through the GitHub releases API, downloads this
manifest from it, then downloads the zip for its platform and checks it against `sha256` before
installing. Schema:

  {
    "schema": 1,
    "release": "media-9.0.2-0.18.0",
    "ffmpeg": "9.0.2",
    "qjs": "0.18.0",
    "platforms": {
      "<platform>": {
        "download_url": "https://github.com/<repo>/releases/download/<tag>/intersect-media-tools-<platform>.zip",
        "sha256": "<hex>",
        "bytes": <int>,
        "ffmpeg": "ffmpeg[.exe]",   # file names inside the zip (flat)
        "qjs": "qjs[.exe]"
      }
    }
  }

A breaking change to this layout means a new file name (…_manifest_v2.json) so plugins already in
the field keep reading the old one.

Stdlib only.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

PLATFORMS = ("linux-x64", "linux-arm64", "macos-arm64", "macos-x64", "win-x64", "win-arm64")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input-dir", type=Path, required=True)
    parser.add_argument("--repo", required=True, help="owner/name, e.g. $GITHUB_REPOSITORY")
    parser.add_argument("--tag", required=True)
    parser.add_argument("--ffmpeg-version", required=True)
    parser.add_argument("--qjs-version", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--base-url",
                        help="where the zips live, instead of the GitHub release (local testing: "
                             "a file:// folder URL, used with INTERSECT_MEDIA_TOOLS_MANIFEST)")
    parser.add_argument("--platforms", nargs="+", choices=PLATFORMS, default=list(PLATFORMS),
                        help="subset of platforms (local testing only; releases need all six)")
    args = parser.parse_args()
    base = (args.base_url.rstrip("/") if args.base_url
            else f"https://github.com/{args.repo}/releases/download/{args.tag}")

    platforms = {}
    for platform in args.platforms:
        name = f"intersect-media-tools-{platform}.zip"
        path = args.input_dir / name
        if not path.is_file():
            raise SystemExit(f"error: {path} missing; every platform must be built before publishing")
        exe = ".exe" if platform.startswith("win-") else ""
        platforms[platform] = {
            "download_url": f"{base}/{name}",
            "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
            "bytes": path.stat().st_size,
            "ffmpeg": f"ffmpeg{exe}",
            "qjs": f"qjs{exe}",
        }

    manifest = {
        "schema": 1,
        "release": args.tag,
        "ffmpeg": args.ffmpeg_version,
        "qjs": args.qjs_version,
        "platforms": platforms,
    }
    args.output.write_text(json.dumps(manifest, indent=2) + "\n")
    print(args.output.read_text())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
