# Repack the Microsoft.ML.OnnxRuntime.DirectML NuGet package into our bundle shape.
# Usage:
#   pwsh -File repack_windows_directml.ps1 -OrtVersion 1.24.2 -Output path\to\onnxruntime-win-x64-directml.zip

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$OrtVersion,
    [Parameter(Mandatory=$true)][string]$Output
)

$ErrorActionPreference = 'Stop'

$work = Join-Path $env:RUNNER_TEMP ("ort-dml-" + [guid]::NewGuid().ToString("N"))
if (-not $env:RUNNER_TEMP) { $work = Join-Path $env:TEMP ("ort-dml-" + [guid]::NewGuid().ToString("N")) }
New-Item -ItemType Directory -Force -Path $work | Out-Null

try {
    $nupkg = Join-Path $work "ort-dml.nupkg"
    $url = "https://www.nuget.org/api/v2/package/Microsoft.ML.OnnxRuntime.DirectML/$OrtVersion"
    Write-Host ">> downloading $url"
    Invoke-WebRequest -Uri $url -OutFile $nupkg -UseBasicParsing

    $extract = Join-Path $work "nupkg"
    Write-Host ">> extracting"
    # A .nupkg is a zip; Expand-Archive requires .zip extension on some versions.
    Copy-Item $nupkg ($nupkg + ".zip") -Force
    Expand-Archive -Path ($nupkg + ".zip") -DestinationPath $extract -Force

    $native = Join-Path $extract "runtimes\win-x64\native"
    $headers = Join-Path $extract "build\native\include"
    foreach ($p in @($native, $headers)) {
        if (-not (Test-Path $p)) { throw "expected path missing in nupkg: $p" }
    }

    $stage = Join-Path $work "stage"
    $stageLib = Join-Path $stage "lib"
    $stageInc = Join-Path $stage "include"
    New-Item -ItemType Directory -Force -Path $stageLib, $stageInc | Out-Null

    # Only the .dlls we want in lib/ — skip .pdb/.lib to keep the bundle small.
    foreach ($dll in @("onnxruntime.dll", "DirectML.dll")) {
        $src = Join-Path $native $dll
        if (-not (Test-Path $src)) { throw "missing $dll in nupkg" }
        Copy-Item $src $stageLib -Force
    }

    Copy-Item -Recurse -Force (Join-Path $headers "*") $stageInc

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
