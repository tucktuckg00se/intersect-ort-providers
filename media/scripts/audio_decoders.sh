#!/usr/bin/env bash
# Print FFmpeg's audio decoders as a comma-separated list for --enable-decoder=.
#
# Reads the decoder registry (libavcodec/allcodecs.c) and keeps every decoder declared between the
# "/* audio codecs */" and "/* subtitles */" section comments. That span covers FFmpeg's native
# audio, PCM, DPCM and ADPCM decoders and nothing else (no video, subtitle or external-library
# decoders), so the list stays correct when an FFmpeg bump adds or removes codecs.
#
# usage: audio_decoders.sh <ffmpeg-source-dir>
set -euo pipefail

src="${1:?usage: audio_decoders.sh <ffmpeg-source-dir>}"
registry="$src/libavcodec/allcodecs.c"
[ -f "$registry" ] || { echo "error: $registry not found" >&2; exit 1; }

list=$(awk '
    /\/\* audio codecs \*\// { inside = 1; next }
    /\/\* subtitles \*\//    { inside = 0 }
    inside' "$registry" \
  | grep -oE 'ff_[a-z0-9_]+_decoder' \
  | sed -E 's/^ff_//; s/_decoder$//' \
  | sort -u)

# Sanity check: these must be present or yt-dlp imports from the common sites would fail.
for required in aac opus vorbis mp3float flac alac pcm_s16le; do
    grep -qx "$required" <<<"$list" || { echo "error: decoder '$required' missing from list" >&2; exit 1; }
done

paste -sd, - <<<"$list"
