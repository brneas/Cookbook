# Pure verification rules shared by the release tool and its synthetic tests.
function Confirm-CookbookApk {
    param(
        [Parameter(Mandatory)][string]$Badging,
        [Parameter(Mandatory)][string]$Manifest,
        [Parameter(Mandatory)][string]$Permissions,
        [Parameter(Mandatory)][string]$Certificates,
        [Parameter(Mandatory)][string]$ExpectedCertificateSha256
    )
    $expected = $ExpectedCertificateSha256.Replace(':', '').ToLowerInvariant()
    if ($expected -notmatch '^[0-9a-f]{64}$') { throw 'Expected production fingerprint must contain 64 hexadecimal digits.' }
    if ($Badging -notmatch "package: name='org.tecdesigns.cookbook' versionCode='1' versionName='1.0.0'") { throw 'APK package/version differs from 1.0.0+1.' }
    if ($Badging -notmatch "(?m)^application-label:'Cookbook'$" ) { throw 'Unexpected application label.' }
    if ($Badging -match 'application-debuggable' -or $Manifest -match 'android:debuggable[^\r\n]*0xffffffff') { throw 'Release APK is debuggable.' }
    if ($Manifest -match 'android:debuggable' -and $Manifest -notmatch 'android:debuggable[^\r\n]*=\(type 0x12\)0x0(?:\r?\n|$)') { throw 'Unexpected debuggable flag.' }
    foreach ($flag in @('allowBackup', 'usesCleartextTraffic')) {
        if ($Manifest -notmatch ($flag + '[^\r\n]*=\(type 0x12\)0x0(?:\r?\n|$)')) { throw "Unsafe or absent $flag setting." }
    }
    if ($Manifest -notmatch 'EnableImpeller[^\r\n]*\r?\n[^\r\n]*android:value[^\r\n]*=\(type 0x12\)0x0(?:\r?\n|$)') { throw 'Skia mitigation is absent.' }
    $required = @('android.permission.INTERNET', 'android.permission.POST_NOTIFICATIONS', 'android.permission.VIBRATE', 'android.permission.RECEIVE_BOOT_COMPLETED', 'android.permission.SCHEDULE_EXACT_ALARM', 'org.tecdesigns.cookbook.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION')
    $actual = @([regex]::Matches($Permissions, "(?m)^uses-permission: name='([^']+)'" ) | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
    if (@(Compare-Object ($required | Sort-Object) $actual).Count -ne 0) { throw 'Unexpected or missing Android permissions; review the release manifest.' }
    if ($Badging -notmatch "(?m)^native-code: 'arm64-v8a' 'armeabi-v7a' 'x86_64'$" ) { throw 'Expected a universal APK with all three supported ABIs.' }
    if ($Certificates -match '(?i)Android Debug|androiddebugkey') { throw 'Android Debug certificate is forbidden for public releases.' }
    $signers = [regex]::Matches($Certificates, '(?m)^Signer #\d+ certificate SHA-256 digest: ([0-9a-fA-F]+)\s*$')
    if ($signers.Count -ne 1) { throw 'Expected exactly one verified APK signer.' }
    $fingerprint = $signers[0].Groups[1].Value.ToLowerInvariant()
    if ($fingerprint -ne $expected) { throw 'APK signer does not match the independently recorded production fingerprint.' }
    return $fingerprint
}
