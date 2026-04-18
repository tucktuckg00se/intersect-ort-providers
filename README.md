# intersect-ort-providers

Builds and publishes per-platform / per-GPU ONNX Runtime bundles consumed by the
[INTERSECT plugin](https://github.com/tucktuckg00se/tuckers-sampler) at runtime.

The plugin ships no ORT shared library inside its plugin zip. On first stem
separation it downloads the matching bundle from a release here, extracts it to
the user's app data folder, and `dlopen`s the runtime.

## Triggering a build

GitHub Actions → **Build ORT Bundles** → Run workflow → set `ort_version`
(default `1.24.2`).

The workflow produces all 7 supported bundles and publishes them as a single
GitHub release tagged `ort-<ort_version>` with a manifest JSON.

## Bundles

| Bundle ID            | Source                                    | Built where         |
| -------------------- | ----------------------------------------- | ------------------- |
| `win-x64-directml`   | Microsoft.ML.OnnxRuntime.DirectML NuGet   | CI (windows-latest) |
| `win-x64-cpu`        | Microsoft `onnxruntime-win-x64-<ver>.zip` | CI (windows-latest) |
| `linux-x64-cpu`      | Microsoft `onnxruntime-linux-x64-<ver>.tgz` | CI (ubuntu-latest) |
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
`https://github.com/tucktuckg00se/intersect-ort-providers/releases/latest/download/intersect_ort_bundles_manifest.json`
to resolve download URLs and sizes without hardcoding asset IDs.

Schema (consumed by `applyOrtManifestEntryToCatalogEntry` in the plugin's
`src/audio/StemSeparation.cpp`):

```json
{
  "ort_version": "1.24.2",
  "bundles": [
    {
      "bundle_id": "linux-x64-cuda12",
      "download_url": "https://github.com/tucktuckg00se/intersect-ort-providers/releases/download/ort-1.24.2/onnxruntime-linux-x64-cuda12.zip",
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

## Keeping in sync with the plugin

The bundle catalog this repo produces must stay aligned with the plugin's
`buildOrtBundleCatalog()` in `src/audio/StemSeparation.cpp`. If you add or
rename a bundle here, update the plugin catalog (and vice versa) in the same
release cycle.
