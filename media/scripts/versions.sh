#!/usr/bin/env bash
# Print the pinned tool versions as key=value lines (suitable for $GITHUB_OUTPUT), read from the
# submodule sources so they can never drift from what is actually built.
set -euo pipefail
media=$(cd "$(dirname "$0")/.." && pwd)
echo "ffmpeg=$(cat "$media/ffmpeg/RELEASE")"
echo "qjs=$(awk '/define QJS_VERSION_(MAJOR|MINOR|PATCH)/ { v = v (v ? "." : "") $3 } END { print v }' "$media/quickjs/quickjs.h")"
