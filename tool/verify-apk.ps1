#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Apk,
    [Parameter(Mandatory)][string]$ExpectedCertificateSha256,
    [Parameter(Mandatory)][string]$BuildTools
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'apk_checks.ps1')
function Read-ToolOutput([string]$Executable, [string[]]$Arguments) {
    $result = & $Executable @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Android tool failed: $([IO.Path]::GetFileName($Executable))." }
    return ($result -join "`n")
}
$apkPath = (Resolve-Path -LiteralPath $Apk).Path
$aapt = Join-Path $BuildTools $(if ($IsWindows) { 'aapt.exe' } else { 'aapt' })
$apksigner = Join-Path $BuildTools $(if ($IsWindows) { 'apksigner.bat' } else { 'apksigner' })
$badging = Read-ToolOutput $aapt @('dump', 'badging', $apkPath)
$manifest = Read-ToolOutput $aapt @('dump', 'xmltree', $apkPath, 'AndroidManifest.xml')
$permissions = Read-ToolOutput $aapt @('dump', 'permissions', $apkPath)
$certificates = Read-ToolOutput $apksigner @('verify', '--verbose', '--print-certs', $apkPath)
$fingerprint = Confirm-CookbookApk -Badging $badging -Manifest $manifest -Permissions $permissions -Certificates $certificates -ExpectedCertificateSha256 $ExpectedCertificateSha256
Write-Host "Verified Cookbook 1.0.0+1 universal production APK. Certificate SHA-256: $fingerprint"
