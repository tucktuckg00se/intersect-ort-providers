# intersect-tools

Builds and publishes the runtimes the
[INTERSECT plugin](https://github.com/tucktuckg00se/tuckers-sampler) downloads on demand:
per-platform / per-GPU ONNX Runtime bundles for stem separation, and ffmpeg + QuickJS for
Import from URL (see [Media tools](#media-tools-import-from-url)).

This repo used to be called `intersect-ort-providers`. GitHub redirects the old URLs, and
INTERSECT 0.19.0 and earlier still use them, so the old name must never be reused.

The plugin ships no ORT shared library inside its plugin zip. On first stem
separation it downloads the matching bundle from a release here, extracts it to
the user's app data folder, and `dlopen`s the runtime.

## Triggering a build

GitHub Actions → **Build ORT Bundles** → Run workflow → set `ort_version`
(default `1.24.2`).

The workflow produces all 9 supported bundles and publishes them as a single
GitHub release tagged `ort-<ort_version>` with a manifest JSON.

## Bundles

| Bundle ID            | Source                                    | Built where         |
| -------------------- | ----------------------------------------- | ------------------- |
| `win-x64-directml`   | Microsoft.ML.OnnxRuntime.DirectML NuGet   | CI (windows-latest) |
| `win-x64-cpu`        | Microsoft `onnxruntime-win-x64-<ver>.zip` | CI (windows-latest) |
| `win-arm64-cpu`      | Microsoft `onnxruntime-win-arm64-<ver>.zip` | CI (windows-latest) |
| `linux-x64-cpu`      | Microsoft `onnxruntime-linux-x64-<ver>.tgz` | CI (ubuntu-latest) |
| `linux-arm64-cpu`    | Microsoft `onnxruntime-linux-aarch64-<ver>.tgz` | CI (ubuntu-latest) |
| `linux-x64-cuda12`   | Microsoft `onnxruntime-linux-x64-gpu-cuda12-<ver>.tgz` | CI (ubuntu-latest) |
| `linux-x64-cuda13`   | Microsoft `onnxruntime-linux-x64-gpu-cuda13-<ver>.tgz` | CI (ubuntu-latest) |
| `linux-x64-migraphx` | Self-built from `microsoft/onnxruntime` source with `--use_migraphx` | CI (ubuntu-latest, `rocm/dev-ubuntu-22.04` container) |
| `macos-arm64`        | Microsoft `onnxruntime-osx-arm64-<ver>.tgz` (renamed) | CI (macos-14) |

The MIGraphX job compiles ORT from source against ROCm headers that ship in
the `rocm/dev-ubuntu-22.04` image. No AMD GPU is needed on the runner —
`./build.sh` runs with `--skip_tests`, and dev headers + libraries are all
that's required to produce the bundle.

## Bundle shape

Every bundle is a `.zip` with this top-level layout (no version-named wrapper
folder inside the zip):

```
lib/
  <core ORT shared lib>
  <provider shared libs, if applicable>
include/
  onnxruntime/...
```

The plugin extracts the zip into `<appdata>/INTERSECT/ort/<bundle-id>/<ort-version>/`
using `juce::ZipFile::uncompressTo` (no system `tar` dependency).

## Manifest

Each release publishes `intersect_ort_bundles_manifest.json` alongside the
bundle zips. The plugin fetches the latest manifest from
`https://github.com/tucktuckg00se/intersect-tools/releases/latest/download/intersect_ort_bundles_manifest.json`
to resolve download URLs and sizes without hardcoding asset IDs.

Schema (consumed by `applyOrtManifestEntryToCatalogEntry` in the plugin's
`src/audio/StemSeparation.cpp`):

```json
{
  "ort_version": "1.24.2",
  "bundles": [
    {
      "bundle_id": "linux-x64-cuda12",
      "download_url": "https://github.com/tucktuckg00se/intersect-tools/releases/download/ort-1.24.2/onnxruntime-linux-x64-cuda12.zip",
      "download_bytes": 420000000,
      "library_file": "libonnxruntime.so",
      "sha256": "..."
    }
  ]
}
```

`bundle_id` must match the plugin catalog's `directoryName` field (kebab-case).
`sha256` is emitted but not currently verified by the plugin.

## Versioning

The plugin's `INTERSECT_ORT_VERSION` (in its `CMakeLists.txt`) is the
authoritative pin. When that moves, run this workflow against the new version
and rebuild + republish the MIGraphX bundle before shipping a plugin release.

## Media tools (Import from URL)

INTERSECT's "Import from URL" runs [yt-dlp](https://github.com/yt-dlp/yt-dlp), which needs two
helpers. Both are built here from official sources pinned as git submodules:

| Tool | Submodule | Why |
| ---- | --------- | --- |
| ffmpeg | `media/ffmpeg` → [FFmpeg/FFmpeg](https://github.com/FFmpeg/FFmpeg) (release tag) | turns whatever audio a site serves into WAV |
| qjs | `media/quickjs` → [quickjs-ng/quickjs](https://github.com/quickjs-ng/quickjs) (release tag) | the JavaScript runtime yt-dlp needs for YouTube |

**yt-dlp itself is not built or hosted here.** The plugin downloads it from yt-dlp's own
releases (checked against their `SHA2-256SUMS`) and keeps it updated from there. These two
helpers rarely need to change, because site changes break yt-dlp, not ffmpeg or QuickJS.

**The ffmpeg build** is LGPL and audio-focused. It keeps every demuxer and every audio decoder,
has PCM/WAV output only, no network protocols, and no ffprobe/ffplay. That's about 8 MB, or about
4.5 MB per platform zip together with qjs. `media/scripts/build_tools.sh` has the configure line,
and each zip's `BUILDINFO.txt` records it too.

**Building:** GitHub Actions → **Build Media Tools** → Run workflow.
- Every run builds all six platforms (linux-x64/arm64, macos-arm64/x64, win-x64/arm64).
- Linux builds run in `ubuntu:22.04` (glibc ≤ 2.35). Windows builds cross-compile with a
  pinned llvm-mingw.
- Each build is smoke-tested on a native runner of its platform with
  `media/scripts/smoke_test.py`, using local fixtures plus the official yt-dlp through `file://`
  URLs (no websites).
- Tick **publish** to create a `media-<ffmpeg>-<qjs>` release.

**Releases are never marked "latest".** Installed plugins read the ORT manifest from
`releases/latest/download/…`, so "latest" must stay on the newest `ort-*` release; the publish
job checks this. The plugin finds the newest `media-*` release through the releases API. Each
media release contains:

- `intersect-media-tools-<platform>.zip`: flat `ffmpeg[.exe]`, `qjs[.exe]`, licences and
  `BUILDINFO.txt`.
- `intersect_media_tools_manifest.json`: per-platform `download_url`, `sha256`, `bytes` and file
  names. The schema is in `media/scripts/emit_media_manifest.py`.
- `ffmpeg-<version>-source.tar.xz`: the exact FFmpeg source, for the LGPL.

**Updating:** the weekly **Check Upstream Media Releases** workflow opens an issue when FFmpeg or
QuickJS-NG ships a newer stable release. To bump:
1. `git -C media/ffmpeg fetch --depth 1 origin tag <tag> && git -C media/ffmpeg checkout <tag>`
   (same for `media/quickjs`).
2. Commit, then run the workflow, then run it again with publish ticked.

To build one platform locally, run `bash media/scripts/build_tools.sh --target linux-x64 --out out`
inside `ubuntu:22.04`, after `media/scripts/ci_deps_ubuntu.sh`.

The fixtures in `media/fixtures` are generated tones (CC0); `media/fixtures/generate.sh` recreates
them.

## Keeping in sync with the plugin

The bundle catalog this repo produces must stay aligned with the plugin's
`buildOrtBundleCatalog()` in `src/audio/StemSeparation.cpp`. If you add or
rename a bundle here, update the plugin catalog (and vice versa) in the same
release cycle.
