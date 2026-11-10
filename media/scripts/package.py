#!/usr/bin/env python3
"""Zip a staged media-tools folder into intersect-media-tools-<platform>.zip.

The zip is flat (no wrapper folder) so the plugin can extract it straight into its versioned tools
folder. Executables get Unix mode 0755 in the zip so ordinary unzip tools keep the exec bit.
INTERSECT itself extracts with juce::ZipFile, which ignores modes, so the plugin sets the bit
again after extracting.

Stdlib only.
"""
from __future__ import annotations

import argparse
import zipfile
from pathlib import Path

EXECUTABLES = {"ffmpeg", "ffmpeg.exe", "qjs", "qjs.exe"}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--stage", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    files = sorted(p for p in args.stage.iterdir() if p.is_file())
    names = {p.name for p in files}
    if not ({"ffmpeg", "ffmpeg.exe"} & names and {"qjs", "qjs.exe"} & names):
        raise SystemExit(f"error: {args.stage} must contain ffmpeg and qjs")

    args.output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(args.output, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as zf:
        for path in files:
            info = zipfile.ZipInfo(path.name, date_time=(2020, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.create_system = 3  # Unix, so external_attr carries a mode
            mode = 0o755 if path.name in EXECUTABLES else 0o644
            info.external_attr = (0o100000 | mode) << 16
            zf.writestr(info, path.read_bytes())

    print(f"{args.output} ({args.output.stat().st_size} bytes): {', '.join(p.name for p in files)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
