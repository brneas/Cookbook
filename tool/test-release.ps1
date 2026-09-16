#Requires -Version 7.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'apk_checks.ps1')
$fingerprint = 'a' * 64
$valid = @{
    Badging = "package: name='org.tecdesigns.cookbook' versionCode='1' versionName='1.0.0'`napplication-label:'Cookbook'`nnative-code: 'arm64-v8a' 'armeabi-v7a' 'x86_64'"
    Manifest = "android:allowBackup=(type 0x12)0x0`nandroid:usesCleartextTraffic=(type 0x12)0x0`nandroid:name=io.flutter.embedding.android.EnableImpeller`nandroid:value=(type 0x12)0x0`n"
    Permissions = (@('android.permission.INTERNET', 'android.permission.POST_NOTIFICATIONS', 'android.permission.VIBRATE', 'android.permission.RECEIVE_BOOT_COMPLETED', 'android.permission.SCHEDULE_EXACT_ALARM', 'org.tecdesigns.cookbook.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION') | ForEach-Object { "uses-permission: name='$_'" }) -join "`n"
    Certificates = "Signer #1 certificate DN: CN=Synthetic Release Fixture`nSigner #1 certificate SHA-256 digest: $fingerprint"
    ExpectedCertificateSha256 = $fingerprint
}
if ((Confirm-CookbookApk @valid) -ne $fingerprint) { throw 'Valid synthetic metadata rejected.' }
$cases = @(
    @{Badging = $valid.Badging.Replace("versionCode='1'", "versionCode='2001'")},
    @{Badging = $valid.Badging.Replace("versionName='1.0.0'", "versionName='0.0.0'")},
    @{Badging = $valid.Badging.Replace('org.tecdesigns.cookbook', 'example.wrong')},
    @{Badging = $valid.Badging.Replace("application-label:'Cookbook'", "application-label:'Wrong'")},
    @{Badging = $valid.Badging + "`napplication-debuggable"},
    @{Manifest = $valid.Manifest.Replace('allowBackup=(type 0x12)0x0', 'allowBackup=(type 0x12)0xffffffff')},
    @{Manifest = $valid.Manifest.Replace('usesCleartextTraffic=(type 0x12)0x0', 'usesCleartextTraffic=(type 0x12)0xffffffff')},
    @{Manifest = $valid.Manifest.Replace('EnableImpeller', 'OtherFlag')},
    @{Permissions = $valid.Permissions + "`nuses-permission: name='android.permission.ACCESS_FINE_LOCATION'"},
    @{Badging = $valid.Badging.Replace(" 'armeabi-v7a' 'x86_64'", '')},
    @{Certificates = $valid.Certificates.Replace('Synthetic Release Fixture', 'Android Debug')},
    @{ExpectedCertificateSha256 = 'b' * 64},
    @{Certificates = $valid.Certificates + "`nSigner #2 certificate SHA-256 digest: $fingerprint"},
    @{ExpectedCertificateSha256 = 'invalid'}
)
foreach ($case in $cases) {
    $candidate = $valid.Clone()
    foreach ($key in $case.Keys) { $candidate[$key] = $case[$key] }
    $rejected = $false
    try { $null = Confirm-CookbookApk @candidate } catch { $rejected = $true }
    if (-not $rejected) { throw "Invalid metadata accepted: $($case.Keys -join ', ')" }
}
Write-Host 'Release verification: 15 synthetic checks succeeded.'
