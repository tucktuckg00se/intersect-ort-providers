#!/usr/bin/env bash
# Repack upstream Microsoft macOS arm64 ORT tarball into our zip bundle shape.
# Upstream still uses "osx" in the asset name; we rename on output to "macos".
#
# Usage:
#   repack_macos_arm64.sh --ort-version X.Y.Z --output /path/onnxruntime-macos-arm64.zip

set -euo pipefail

die() { echo "error: $*" >&2; exit 1; }

ORT_VERSION=""
OUTPUT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ort-version) ORT_VERSION="$2"; shift 2 ;;
    --output)      OUTPUT="$2"; shift 2 ;;
    *) die "unknown arg: $1" ;;
  esac
done

[[ -n "$ORT_VERSION" && -n "$OUTPUT" ]] || die "missing required args"

ASSET="onnxruntime-osx-arm64-${ORT_VERSION}.tgz"
URL="https://github.com/microsoft/onnxruntime/releases/download/v${ORT_VERSION}/${ASSET}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo ">> downloading $URL"
curl -fSL --retry 3 -o "$WORK/$ASSET" "$URL"

echo ">> extracting"
tar -xzf "$WORK/$ASSET" -C "$WORK"

EXTRACTED="$(find "$WORK" -maxdepth 1 -mindepth 1 -type d | head -n1)"
[[ -d "$EXTRACTED/lib" && -d "$EXTRACTED/include" ]] || die "upstream layout unexpected under $EXTRACTED"

STAGE="$WORK/stage"
mkdir -p "$STAGE"
cp -a "$EXTRACTED/lib" "$STAGE/"
cp -a "$EXTRACTED/include" "$STAGE/"

echo ">> repacking to $OUTPUT"
mkdir -p "$(dirname "$OUTPUT")"
( cd "$STAGE" && zip --symlinks -qr "$OUTPUT" lib include )

echo ">> done: $(du -h "$OUTPUT" | cut -f1) $OUTPUT"
