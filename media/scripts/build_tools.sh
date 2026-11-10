#!/usr/bin/env bash
# Build the URL-import media tools for one INTERSECT platform and package them.
#
#   ffmpeg  audio-focused LGPL build: every demuxer, every audio decoder, PCM/WAV output only,
#           no network, no ffprobe/ffplay. yt-dlp uses it to turn whatever audio a site serves
#           into WAV.
#   qjs     QuickJS-NG, the JavaScript runtime yt-dlp needs for YouTube.
#
# Both come from the official submodules in media/ffmpeg and media/quickjs.
#
# usage: build_tools.sh --target <platform> --out <dir> [--jobs N]
#   <platform>: linux-x64 | linux-arm64 | macos-arm64 | macos-x64 | win-x64 | win-arm64
#
# Linux targets build natively; run them inside ubuntu:22.04 so the binaries need glibc <= 2.35.
# macOS targets build natively on a runner of the matching architecture.
# Windows targets cross-compile with llvm-mingw; its bin/ directory must be on PATH.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
media=$(dirname "$here")
target=""
out=""
jobs=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)

while [ $# -gt 0 ]; do
    case "$1" in
        --target) target="$2"; shift 2 ;;
        --out)    out="$2"; shift 2 ;;
        --jobs)   jobs="$2"; shift 2 ;;
        *) echo "error: unknown argument $1" >&2; exit 2 ;;
    esac
done
[ -n "$target" ] && [ -n "$out" ] || { echo "usage: build_tools.sh --target <platform> --out <dir>" >&2; exit 2; }

ffsrc="$media/ffmpeg"
qjssrc="$media/quickjs"
[ -f "$ffsrc/configure" ] && [ -f "$qjssrc/CMakeLists.txt" ] || {
    echo "error: submodules missing; run: git submodule update --init --depth 1" >&2; exit 1; }

mkdir -p "$out"
out=$(cd "$out" && pwd)
work="${WORK_DIR:-$PWD/work-media}/$target"
rm -rf "$work"
mkdir -p "$work/ffmpeg" "$work/qjs" "$work/stage"

exe=""
strip_cmd=(strip)
ff_target=()
cmake_target=()
case "$target" in
    linux-x64|linux-arm64) ;;
    macos-arm64|macos-x64)
        if [ "$target" = macos-arm64 ]; then min=11.0; mac_arch=arm64; else min=10.15; mac_arch=x86_64; fi
        [ "$(uname -m)" = "$mac_arch" ] || { echo "error: build $target on a $mac_arch Mac" >&2; exit 1; }
        ff_target=(--extra-cflags="-mmacosx-version-min=$min" --extra-ldflags="-mmacosx-version-min=$min")
        cmake_target=(-DCMAKE_OSX_DEPLOYMENT_TARGET="$min" -DCMAKE_OSX_ARCHITECTURES="$mac_arch")
        ;;
    win-x64|win-arm64)
        if [ "$target" = win-x64 ]; then arch=x86_64; else arch=aarch64; fi
        triple="$arch-w64-mingw32"
        command -v "$triple-clang" >/dev/null || { echo "error: $triple-clang not found; put llvm-mingw/bin on PATH" >&2; exit 1; }
        exe=".exe"
        strip_cmd=("$triple-strip")
        ff_target=(--enable-cross-compile --target-os=mingw32 --arch="$arch"
                   --cross-prefix="$triple-" --cc="$triple-clang" --extra-ldflags=-static)
        cmake_target=(-DCMAKE_SYSTEM_NAME=Windows -DCMAKE_SYSTEM_PROCESSOR="$arch"
                      -DCMAKE_C_COMPILER="$triple-clang" -DCMAKE_RC_COMPILER="$triple-windres"
                      -DCMAKE_EXE_LINKER_FLAGS=-static)
        ;;
    *) echo "error: unknown target $target" >&2; exit 2 ;;
esac

decoders=$("$here/audio_decoders.sh" "$ffsrc")

ff_flags=(
    --enable-static --disable-shared
    --disable-autodetect --disable-network --disable-doc --disable-debug --disable-x86asm
    --disable-ffplay --disable-ffprobe --disable-avdevice --disable-swscale
    --disable-decoders --enable-decoder="$decoders"
    --disable-encoders --enable-encoder=pcm_s16le,pcm_s24le,pcm_f32le
    # mp4 is here because yt-dlp passes -movflags to every ffmpeg call, and that option only
    # exists when a mov-family muxer is built.
    --disable-muxers --enable-muxer=wav,mp4,ipod,mov,matroska,webm,ogg,mp3,adts,flac
    --disable-filters --enable-filter=aresample,aformat,anull,atrim,volume
    --disable-protocols --enable-protocol=file,pipe
    --extra-version=intersect
)

echo "== ffmpeg $(cat "$ffsrc/RELEASE") for $target"
(
    cd "$work/ffmpeg"
    "$ffsrc/configure" "${ff_flags[@]}" ${ff_target[@]+"${ff_target[@]}"} > configure.log 2>&1 \
        || { tail -40 configure.log; ffbuild_log="$work/ffmpeg/ffbuild/config.log"; [ -f "$ffbuild_log" ] && tail -40 "$ffbuild_log"; exit 1; }
    grep -E '^(Programs|License):' -A1 configure.log
    make -j"$jobs" "ffmpeg$exe" > make.log 2>&1 || { tail -40 make.log; exit 1; }
)
cp "$work/ffmpeg/ffmpeg$exe" "$work/stage/ffmpeg$exe"

qjs_version=$(awk '/define QJS_VERSION_(MAJOR|MINOR|PATCH)/ { v = v (v ? "." : "") $3 } END { print v }' "$qjssrc/quickjs.h")
echo "== qjs $qjs_version for $target"
cmake -S "$qjssrc" -B "$work/qjs" -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
      -DQJS_ENABLE_INSTALL=OFF ${cmake_target[@]+"${cmake_target[@]}"} > "$work/qjs/configure.log" 2>&1 \
    || { tail -40 "$work/qjs/configure.log"; exit 1; }
cmake --build "$work/qjs" --target qjs_exe --parallel "$jobs" > "$work/qjs/build.log" 2>&1 \
    || { tail -40 "$work/qjs/build.log"; exit 1; }
qjs_bin=$(find "$work/qjs" -name "qjs$exe" -type f | head -1)
[ -n "$qjs_bin" ] || { echo "error: qjs$exe not produced" >&2; exit 1; }
cp "$qjs_bin" "$work/stage/qjs$exe"
"${strip_cmd[@]}" "$work/stage/qjs$exe"

if [ "${target%%-*}" = macos ]; then
    # Ad-hoc signatures: arm64 macOS refuses to run unsigned code, and the plugin itself is
    # ad-hoc signed the same way.
    codesign --force --sign - "$work/stage/ffmpeg" "$work/stage/qjs"
fi

cp "$ffsrc/LICENSE.md" "$work/stage/LICENSE.ffmpeg.md"
cp "$ffsrc/COPYING.LGPLv2.1" "$work/stage/COPYING.ffmpeg.LGPLv2.1"
cp "$qjssrc/LICENSE" "$work/stage/LICENSE.quickjs"
{
    echo "INTERSECT media tools for $target"
    echo "ffmpeg $(cat "$ffsrc/RELEASE") ($(git -C "$ffsrc" rev-parse HEAD 2>/dev/null || echo unknown commit)), LGPL-2.1-or-later"
    echo "  source: https://github.com/FFmpeg/FFmpeg (the release also carries the source tarball)"
    echo "  configure: ${ff_flags[*]} ${ff_target[*]+${ff_target[*]}}"
    echo "qjs $qjs_version ($(git -C "$qjssrc" rev-parse HEAD 2>/dev/null || echo unknown commit)), MIT"
    echo "  source: https://github.com/quickjs-ng/quickjs"
} > "$work/stage/BUILDINFO.txt"

python3 "$here/package.py" --stage "$work/stage" --output "$out/intersect-media-tools-$target.zip"
echo "== wrote $out/intersect-media-tools-$target.zip"
