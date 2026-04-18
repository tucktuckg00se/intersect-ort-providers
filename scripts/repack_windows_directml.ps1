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
    # onnxruntime.dll + headers come from Microsoft.ML.OnnxRuntime.DirectML.
    # DirectML.dll lives in a separate NuGet (Microsoft.AI.DirectML) — the ORT
    # package only pulls it in as a transitive NuGet dependency, so we have to
    # fetch it explicitly here.
    $ortNupkg = Join-Path $work "ort-dml.nupkg"
    $ortUrl = "https://www.nuget.org/api/v2/package/Microsoft.ML.OnnxRuntime.DirectML/$OrtVersion"
    Write-Host ">> downloading $ortUrl"
    Invoke-WebRequest -Uri $ortUrl -OutFile $ortNupkg -UseBasicParsing

    $ortExtract = Join-Path $work "ort-nupkg"
    Write-Host ">> extracting ORT nupkg"
    Copy-Item $ortNupkg ($ortNupkg + ".zip") -Force
    Expand-Archive -Path ($ortNupkg + ".zip") -DestinationPath $ortExtract -Force

    $ortNative = Join-Path $ortExtract "runtimes\win-x64\native"
    $headers = Join-Path $ortExtract "build\native\include"
    foreach ($p in @($ortNative, $headers)) {
        if (-not (Test-Path $p)) { throw "expected path missing in ORT nupkg: $p" }
    }

    # Pull DirectML.dll out of Microsoft.AI.DirectML. No version pin — we take
    # whatever the latest stable is, which is what ORT binds against at build
    # time anyway.
    $dmlNupkg = Join-Path $work "ai-dml.nupkg"
    $dmlUrl = "https://www.nuget.org/api/v2/package/Microsoft.AI.DirectML"
    Write-Host ">> downloading $dmlUrl"
    Invoke-WebRequest -Uri $dmlUrl -OutFile $dmlNupkg -UseBasicParsing

    $dmlExtract = Join-Path $work "dml-nupkg"
    Write-Host ">> extracting DirectML nupkg"
    Copy-Item $dmlNupkg ($dmlNupkg + ".zip") -Force
    Expand-Archive -Path ($dmlNupkg + ".zip") -DestinationPath $dmlExtract -Force

    $dmlDll = Join-Path $dmlExtract "bin\x64-win\DirectML.dll"
    if (-not (Test-Path $dmlDll)) { throw "DirectML.dll not found at $dmlDll" }

    $stage = Join-Path $work "stage"
    $stageLib = Join-Path $stage "lib"
    $stageInc = Join-Path $stage "include"
    New-Item -ItemType Directory -Force -Path $stageLib, $stageInc | Out-Null

    # Only the .dlls we want in lib/ — skip .pdb/.lib to keep the bundle small.
    $ortDll = Join-Path $ortNative "onnxruntime.dll"
    if (-not (Test-Path $ortDll)) { throw "missing onnxruntime.dll in ORT nupkg" }
    Copy-Item $ortDll $stageLib -Force
    Copy-Item $dmlDll $stageLib -Force

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
