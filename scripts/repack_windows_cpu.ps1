# Repack the upstream Microsoft onnxruntime-win-x64-<ver>.zip into our bundle shape.
# Usage:
#   pwsh -File repack_windows_cpu.ps1 -OrtVersion 1.24.2 -Output path\to\onnxruntime-win-x64-cpu.zip

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$OrtVersion,
    [Parameter(Mandatory=$true)][string]$Output
)

$ErrorActionPreference = 'Stop'

$work = Join-Path $env:RUNNER_TEMP ("ort-wincpu-" + [guid]::NewGuid().ToString("N"))
if (-not $env:RUNNER_TEMP) { $work = Join-Path $env:TEMP ("ort-wincpu-" + [guid]::NewGuid().ToString("N")) }
New-Item -ItemType Directory -Force -Path $work | Out-Null

try {
    $asset = "onnxruntime-win-x64-$OrtVersion.zip"
    $url = "https://github.com/microsoft/onnxruntime/releases/download/v$OrtVersion/$asset"
    $zip = Join-Path $work $asset
    Write-Host ">> downloading $url"
    Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing

    $extract = Join-Path $work "upstream"
    Write-Host ">> extracting"
    Expand-Archive -Path $zip -DestinationPath $extract -Force

    # Upstream zip expands to onnxruntime-win-x64-<ver>/{lib,include}
    $inner = Get-ChildItem -Directory $extract | Select-Object -First 1
    if (-not $inner) { throw "upstream zip had no top-level directory" }
    $srcLib = Join-Path $inner.FullName "lib"
    $srcInc = Join-Path $inner.FullName "include"
    foreach ($p in @($srcLib, $srcInc)) {
        if (-not (Test-Path $p)) { throw "missing expected dir in upstream zip: $p" }
    }

    $stage = Join-Path $work "stage"
    $stageLib = Join-Path $stage "lib"
    $stageInc = Join-Path $stage "include"
    New-Item -ItemType Directory -Force -Path $stageLib, $stageInc | Out-Null

    # Keep only runtime files (.dll) in lib/ — drop .lib/.pdb to trim size.
    Get-ChildItem -Path $srcLib -Filter *.dll | Copy-Item -Destination $stageLib -Force
    Copy-Item -Recurse -Force (Join-Path $srcInc "*") $stageInc

    Write-Host ">> repacking to $Output"
    $outDir = Split-Path -Parent $Output
    if ($outDir -and -not (Test-Path $outDir)) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }
    if (Test-Path $Output) { Remove-Item $Output -Force }
    Compress-Archive -Path (Join-Path $stage "*") -DestinationPath $Output -CompressionLevel Optimal

    $size = (Get-Item $Output).Length
    Write-Host (">> done: {0:N0} bytes  {1}" -f $size, $Output)
} finally {
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}
