#!/usr/bin/env bash
# Install build dependencies inside a fresh ubuntu:22.04 container (CI and local test builds).
#
# usage: ci_deps_ubuntu.sh [--llvm-mingw <install-dir>]
#   --llvm-mingw  also fetch the pinned llvm-mingw toolchain (Windows cross builds, x86_64 hosts)
#                 and verify its sha256. Add <install-dir>/bin to PATH afterwards.
set -euo pipefail

# Bump together: version, then the asset's sha256 (GitHub shows it as the asset "digest").
LLVM_MINGW_VERSION=20261104
LLVM_MINGW_SHA256=919380403de87dca3c581c2053230cd298af5e891286628ba0613b7fed370926

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
    build-essential cmake git python3 xz-utils curl ca-certificates file binutils > /dev/null
# The checkout belongs to the runner user, not the container's root; without this git refuses to
# read it and BUILDINFO.txt loses the submodule commits. Only ever run this script in a container.
(cd / && git config --global --add safe.directory '*')

if [ "${1:-}" = "--llvm-mingw" ]; then
    dest="${2:?usage: ci_deps_ubuntu.sh --llvm-mingw <install-dir>}"
    name="llvm-mingw-$LLVM_MINGW_VERSION-ucrt-ubuntu-22.04-x86_64"
    tmp=$(mktemp -d)
    curl -sSL -o "$tmp/$name.tar.xz" \
        "https://github.com/mstorsjo/llvm-mingw/releases/download/$LLVM_MINGW_VERSION/$name.tar.xz"
    echo "$LLVM_MINGW_SHA256  $tmp/$name.tar.xz" | sha256sum -c -
    mkdir -p "$dest"
    tar -xJf "$tmp/$name.tar.xz" -C "$dest" --strip-components=1
    rm -rf "$tmp"
    echo "llvm-mingw $LLVM_MINGW_VERSION installed in $dest"
fi
