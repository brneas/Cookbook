# Releasing Cookbook

Production signing stays on the maintainer's machine. CI does not receive a keystore and never publishes APKs. Normal `flutter build apk --release` requires local production configuration and has no debug-signing fallback.

## Prepare the source

Review README, changelog, privacy/security policies, dependency notices and [compatibility](compatibility.md). Complete physical-device and disposable-server acceptance: sign-in, offline edits/sync/conflicts, image browsing, Cooking/timer delivery, TalkBack and theme. Enable GitHub private vulnerability reporting before making the repository public.

Version lives in `pubspec.yaml`; the first release is **1.0.0+1**, tag **v1.0.0**. About reads installed Android package metadata. Commit the reviewed source and lockfile with a clean working tree. Update the release script's version assertions when preparing later versions.

## Configure local signing

Generate and protect the permanent Android signing key manually using the [Android signing guidance](https://developer.android.com/studio/publish/app-signing). Keep encrypted offline backups and record the certificate SHA-256 fingerprint independently. Losing this identity can prevent upgrades. This repository does not generate keys.

Copy `android/key.properties.example` to ignored `android/key.properties`. Replace all placeholders locally. `storeFile` resolves relative to `android/` unless absolute; use forward slashes and keep the keystore outside the repository. Restrict access to the properties file and keystore. Never commit either, store them in GitHub secrets, paste passwords into commands, or print them in logs.

Use a production identity, not the Android Debug certificate. The old development-release switch is not supported. Unset it in a process that previously used it. The release verifier rejects debug certificates and requires your independently recorded SHA-256 fingerprint.

## Build and verify

Use the exact [build toolchain](building.md). In PowerShell 7, from the clean repository root:

```powershell
./tool/release.ps1 -BuildTools $AndroidBuildToolsDirectory -ExpectedCertificateSha256 $ProductionCertificateSha256
```

The two variables hold the local Android build-tools directory and the public certificate fingerprint, not passwords. The script checks committed/clean source and version, enforces the lockfile, runs formatting/analyze/tests, builds the universal release, verifies the APK and only then creates `release/v1.0.0/`. It refuses to overwrite that directory. Review and move an existing directory aside before another build.

The output contains exactly:

```text
cookbook-1.0.0.apk
SHA256SUMS.txt
```

No split APK is published for 1.0.0. Flutter's ABI version-code offsets complicate switching back to universal; a durable multi-channel upgrade strategy is required before publishing splits. Existing development certificates may differ from production, so preserve unsynchronized data before changing installation identities.

`tool/verify-apk.ps1` uses `aapt` and `apksigner verify --verbose --print-certs`. It checks application ID, label, 1.0.0/code 1, non-debuggable status, backup/cleartext flags, explicit Skia setting, exact permission allowlist, universal ABIs and a single expected non-debug signer. It prints the verified certificate SHA-256 fingerprint; record it in the GitHub release notes. Checksums include only the production APK, not development artifacts.

For a separate verification:

```powershell
./tool/verify-apk.ps1 -Apk ./release/v1.0.0/cookbook-1.0.0.apk -BuildTools $AndroidBuildToolsDirectory -ExpectedCertificateSha256 $ProductionCertificateSha256
Get-FileHash ./release/v1.0.0/cookbook-1.0.0.apk -Algorithm SHA256
```

Do not use an unsigned or debug-signed release as the public artifact. Without local signing, validate contributors' builds with `flutter build apk --debug`. `./android/gradlew.bat -p android :app:assembleRelease --dry-run` (PowerShell; use `sh android/gradlew` on Unix) must fail when signing configuration is absent; it does not create a production APK.

## Tag and publish manually

After reviewing the signed APK on a physical device and confirming source/working tree:

```sh
git tag -s v1.0.0 -m "Cookbook 1.0.0"
git verify-tag v1.0.0
git push origin HEAD
git push origin v1.0.0
```

Configure your Git signing identity separately from Android signing. Do not retag a published version. On GitHub, create a **draft** release for v1.0.0, use `RELEASE_NOTES_1.0.0.md`, add the independently verified certificate fingerprint, and attach only the universal APK and its checksum file. GitHub supplies source archives from the tag. Download and recheck draft assets before publishing. No repository script creates tags or uploads anything.
