#!/usr/bin/env bash
# Runs INSIDE a ROCm container (rocm/dev-ubuntu-22.04 in CI, rocm/pytorch
# locally). Builds onnxruntime with --use_migraphx, stages the output, zips it
# to $OUT_DIR/onnxruntime-linux-x64-migraphx.zip.
#
# Expects:
#   ORT_VERSION env var (e.g. 1.24.2)
#   /opt/rocm exists (any rocm/* image satisfies this)
#   OUT_DIR points at a writable dir (defaults to /out, the historical mount path)

set -euo pipefail

die() { echo "error: $*" >&2; exit 1; }

[[ -n "${ORT_VERSION:-}" ]] || die "ORT_VERSION not set"
[[ -d /opt/rocm ]] || die "/opt/rocm missing -- wrong container image?"
OUT_DIR="${OUT_DIR:-/out}"
mkdir -p "$OUT_DIR"
[[ -d "$OUT_DIR" ]] || die "OUT_DIR=$OUT_DIR not a directory"

# Tooling we need that may not be in the image. rocm/dev-ubuntu-22.04 is
# Ubuntu 22.04 Jammy; its apt cmake is 3.22 but ORT 1.24 requires 3.28+, so we
# grab a recent cmake from pip (kitware-backed wheel).
echo ">> installing build prerequisites"
apt-get update
apt-get install -y --no-install-recommends \
  git ca-certificates build-essential python3 python3-pip zip
# rocm-dev is preinstalled in this image but does NOT pull in
# migraphx-dev or miopen-hip-dev despite the name implying otherwise.
# onnxruntime_providers_migraphx.cmake does:
#   find_package(migraphx)        -- needs migraphx-dev
# and migraphx-config.cmake itself does:
#   find_package(MIOpen)          -- needs miopen-hip-dev
# Install both explicitly.
apt-get install -y --no-install-recommends \
  migraphx migraphx-dev \
  miopen-hip-dev rocblas-dev hipblaslt-dev rocrand-dev
rm -rf /var/lib/apt/lists/*
pip3 install --no-cache-dir "cmake>=3.28"
hash -r
echo ">> cmake version: $(cmake --version | head -n1)"

SRC=/tmp/ort-src
rm -rf "$SRC"
echo ">> cloning microsoft/onnxruntime @ v${ORT_VERSION}"
git clone --depth 1 --branch "v${ORT_VERSION}" --recurse-submodules --shallow-submodules \
  https://github.com/microsoft/onnxruntime "$SRC"

cd "$SRC"
echo ">> running build.sh (this is the slow part)"
./build.sh \
  --config Release \
  --build_shared_lib \
  --parallel \
  --use_migraphx \
  --migraphx_home /opt/rocm \
  --rocm_home /opt/rocm \
  --cmake_path "$(command -v cmake)" \
  --skip_tests \
  --allow_running_as_root

BUILD_OUT="$SRC/build/Linux/Release"
[[ -d "$BUILD_OUT" ]] || die "build output dir missing: $BUILD_OUT"

STAGE=/tmp/stage
rm -rf "$STAGE"
mkdir -p "$STAGE/lib" "$STAGE/include"

echo ">> staging libraries"
shopt -s nullglob
copied=0
for pat in \
    "libonnxruntime.so" \
    "libonnxruntime.so.*" \
    "libonnxruntime_providers_migraphx.so" \
    "libonnxruntime_providers_shared.so" \
    "libonnxruntime_providers_rocm.so" ; do
  for f in "$BUILD_OUT"/$pat; do
    [[ -e "$f" ]] || continue
    cp -a "$f" "$STAGE/lib/"
    copied=$((copied + 1))
  done
done
shopt -u nullglob

# Sanity: at minimum the core lib + the migraphx provider must be present.
[[ -e "$STAGE/lib/libonnxruntime_providers_migraphx.so" ]] \
  || die "MIGraphX provider not built -- check build.sh log"
ls "$STAGE/lib/" | grep -q '^libonnxruntime\.so' \
  || die "core libonnxruntime.so not staged"
echo ">> staged $copied library files"

# If build.sh hasn't already produced a versioned soname, create the chain so
# the plugin's findBundleLibraryFile() can resolve unversioned -> versioned.
# (Most ORT builds already do this.)

echo ">> staging headers"
HEADERS_SRC="$SRC/include/onnxruntime"
[[ -d "$HEADERS_SRC" ]] || die "headers source missing: $HEADERS_SRC"
cp -a "$HEADERS_SRC" "$STAGE/include/"

OUT="$OUT_DIR/onnxruntime-linux-x64-migraphx.zip"
rm -f "$OUT"
echo ">> zipping to $OUT"
( cd "$STAGE" && zip --symlinks -qr "$OUT" lib include )

echo ">> done"
ls -la "$OUT"
