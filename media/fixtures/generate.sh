#!/usr/bin/env bash
# Regenerate the smoke-test fixtures: one-second synthetic tones (440 Hz left, 660 Hz right) in
# the containers and codecs that yt-dlp commonly hands to ffmpeg. They are generated, not
# recorded, so they carry no third-party rights (CC0).
#
# Needs a full ffmpeg build with libopus, libvorbis, libmp3lame and libx264 (not the trimmed
# build this repo produces, which has no encoders for these).
#
# usage: media/fixtures/generate.sh [ffmpeg]
set -euo pipefail

ffmpeg="${1:-ffmpeg}"
dir=$(cd "$(dirname "$0")" && pwd)

gen() {
    local out="$1"; shift
    "$ffmpeg" -v error -y \
        -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=1" \
        -f lavfi -i "sine=frequency=660:sample_rate=48000:duration=1" \
        -filter_complex "[0][1]amerge=inputs=2[a]" -map "[a]" \
        "$@" -map_metadata -1 -fflags +bitexact "$dir/$out"
}

gen tone-aac.m4a   -c:a aac -b:a 96k -ar 44100
gen tone-aac.ts    -c:a aac -b:a 96k -f mpegts
gen tone-opus.webm -c:a libopus -b:a 64k
gen tone-opus.opus -c:a libopus -b:a 64k
gen tone-vorbis.ogg -c:a libvorbis -q:a 2
gen tone-mp3.mp3   -c:a libmp3lame -b:a 96k -ar 44100
gen tone-flac.flac -c:a flac -ar 44100 -sample_fmt s16
gen tone-alac.m4a  -c:a alac -ar 44100 -sample_fmt s16p

"$ffmpeg" -v error -y \
    -f lavfi -i "testsrc=size=160x120:rate=15:duration=1" \
    -f lavfi -i "sine=frequency=440:sample_rate=44100:duration=1" \
    -c:v libx264 -preset veryfast -crf 35 -c:a aac -b:a 64k -shortest \
    -map_metadata -1 -fflags +bitexact "$dir/video-h264-aac.mp4"

ls -l "$dir"
