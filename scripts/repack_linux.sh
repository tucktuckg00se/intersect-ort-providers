#!/usr/bin/env bash
# Repack an upstream Microsoft ONNX Runtime Linux x64 tarball into INTERSECT's
# zip bundle shape (lib/ + include/ at the top level, symlinks preserved).
#
# Usage:
#   repack_linux.sh --flavour {cpu|cuda12|cuda13} --ort-version X.Y.Z --output /path/out.zip
#
# Upstream asset naming for ORT 1.24+ (from github.com/microsoft/onnxruntime/releases):
#   cpu     -> onnxruntime-linux-x64-<ver>.tgz
#   cuda12  -> onnxruntime-linux-x64-gpu-cuda12-<ver>.tgz
#   cuda13  -> onnxruntime-linux-x64-gpu-cuda13-<ver>.tgz
# If Microsoft changes this, update URL_CPU/URL_CUDA12/URL_CUDA13 below.

set -euo pipefail

die() { echo "error: $*" >&2; exit 1; }

FLAVOUR=""
ORT_VERSION=""
OUTPUT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --flavour)     FLAVOUR="$2"; shift 2 ;;
    --ort-version) ORT_VERSION="$2"; shift 2 ;;
    --output)      OUTPUT="$2"; shift 2 ;;
    *) die "unknown arg: $1" ;;
  esac
done

[[ -n "$FLAVOUR" && -n "$ORT_VERSION" && -n "$OUTPUT" ]] || die "missing required args"

MS_BASE="https://github.com/microsoft/onnxruntime/releases/download/v${ORT_VERSION}"
case "$FLAVOUR" in
  cpu)    ASSET="onnxruntime-linux-x64-${ORT_VERSION}.tgz" ;;
  cuda12) ASSET="onnxruntime-linux-x64-gpu-cuda12-${ORT_VERSION}.tgz" ;;
  cuda13) ASSET="onnxruntime-linux-x64-gpu-cuda13-${ORT_VERSION}.tgz" ;;
  *) die "flavour must be cpu|cuda12|cuda13, got: $FLAVOUR" ;;
esac

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo ">> downloading $MS_BASE/$ASSET"
curl -fSL --retry 3 -o "$WORK/$ASSET" "$MS_BASE/$ASSET"

echo ">> extracting"
tar -xzf "$WORK/$ASSET" -C "$WORK"

# Upstream tarball expands to onnxruntime-linux-x64-[gpu-*-]VER/{lib,include}
EXTRACTED="$(find "$WORK" -maxdepth 1 -mindepth 1 -type d | head -n1)"
[[ -d "$EXTRACTED/lib" && -d "$EXTRACTED/include" ]] || die "upstream layout unexpected under $EXTRACTED"

STAGE="$WORK/stage"
mkdir -p "$STAGE"
# -a preserves symlinks (libonnxruntime.so -> libonnxruntime.so.1.24.2)
cp -a "$EXTRACTED/lib" "$STAGE/"
cp -a "$EXTRACTED/include" "$STAGE/"

echo ">> repacking to $OUTPUT"
mkdir -p "$(dirname "$OUTPUT")"
# zip --symlinks keeps soname chains intact; JUCE ZipFile does not follow symlinks on extract,
# but dlopen walks the soname chain itself once files are on disk.
( cd "$STAGE" && zip --symlinks -qr "$OUTPUT" lib include )

echo ">> done: $(du -h "$OUTPUT" | cut -f1) $OUTPUT"
