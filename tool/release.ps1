#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ExpectedCertificateSha256,
    [Parameter(Mandatory)][string]$BuildTools
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path -Parent $PSScriptRoot
Push-Location -LiteralPath $root
try {
    function Invoke-Gate([string]$Command, [string[]]$Arguments) {
        & $Command @Arguments
        if ($LASTEXITCODE -ne 0) { throw "Release gate failed: $Command" }
    }
    function Assert-CleanTree {
        $status = & git status --porcelain --untracked-files=all
        if ($LASTEXITCODE -ne 0 -or $status) { throw 'Release requires a clean, committed working tree, including untracked files.' }
    }
    $null = & git rev-parse --verify HEAD 2>&1
    if ($LASTEXITCODE -ne 0) { throw 'Commit the reviewed source before building a public release.' }
    Assert-CleanTree
    $forbidden = & git ls-files -- '*.apk' '*.aab' '*.jks' '*.keystore' '*.p12' '*.db' '*.sqlite' '.env' 'android/key.properties' '*local.properties'
    if ($LASTEXITCODE -ne 0 -or $forbidden) { throw 'Remove private/generated files from the Git index before release.' }
    if ((Get-Content -LiteralPath pubspec.yaml -Raw) -notmatch '(?m)^version: 1\.0\.0\+1\s*$') { throw 'Expected pubspec version 1.0.0+1.' }
    if ($env:COOKBOOK_DEV_RELEASE) { throw 'Development release signing is retired. Remove COOKBOOK_DEV_RELEASE from this process environment.' }
    if (-not (Test-Path -LiteralPath android/key.properties -PathType Leaf)) { throw 'Configure local production signing as documented in docs/releasing.md.' }
    $expected = $ExpectedCertificateSha256.Replace(':', '')
    if ($expected -notmatch '^[0-9a-fA-F]{64}$') { throw 'Supply the independently recorded production certificate SHA-256.' }
    $buildToolsPath = (Resolve-Path -LiteralPath $BuildTools).Path
    $destination = Join-Path $root 'release/v1.0.0'
    if (Test-Path -LiteralPath $destination) { throw 'release/v1.0.0 already exists. Review and move it aside before rebuilding; nothing is overwritten.' }
    $versionJson = & flutter --version --machine
    if ($LASTEXITCODE -ne 0) { throw 'Flutter version check failed.' }
    if (($versionJson | ConvertFrom-Json).frameworkVersion -ne '3.44.6') { throw 'Use Flutter 3.44.6.' }
    Invoke-Gate flutter @('pub', 'get', '--enforce-lockfile')
    Invoke-Gate dart @('format', '--output=none', '--set-exit-if-changed', 'lib', 'test', 'tool')
    Invoke-Gate flutter @('analyze')
    Invoke-Gate flutter @('test')
    & (Join-Path $PSScriptRoot 'test-release.ps1')
    Invoke-Gate flutter @('build', 'apk', '--release')
    $apk = Join-Path $root 'build/app/outputs/flutter-apk/app-release.apk'
    & (Join-Path $PSScriptRoot 'verify-apk.ps1') -Apk $apk -BuildTools $buildToolsPath -ExpectedCertificateSha256 $expected
    Assert-CleanTree
    $null = New-Item -ItemType Directory -Path $destination
    $finalApk = Join-Path $destination 'cookbook-1.0.0.apk'
    Copy-Item -LiteralPath $apk -Destination $finalApk
    $hash = (Get-FileHash -LiteralPath $finalApk -Algorithm SHA256).Hash.ToLowerInvariant()
    [IO.File]::WriteAllText((Join-Path $destination 'SHA256SUMS.txt'), "$hash  cookbook-1.0.0.apk`n", [Text.UTF8Encoding]::new($false))
    Write-Host "Release artifacts verified in release/v1.0.0. No tag or upload was created."

} finally {
    Pop-Location
}
