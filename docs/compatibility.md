# Compatibility

## Supported baseline

- Android **7.0 / API 24** minimum; target/compile API **36**.
- Flutter **3.44.6**, Dart **3.12.2**; pinned dependencies, no broad upgrades during release preparation.
- HTTPS Nextcloud with Cookbook enabled; external Cookbook API epoch **0**, major **1**. Capability negotiation, not the server app version string, determines support. See [Nextcloud integration](nextcloud-integration.md).

## Android renderer

Android explicitly selects Skia with `io.flutter.embedding.android.EnableImpeller=false`. Impeller GLES can abort natively on extreme image decode targets; Dart exception handling cannot recover from a native abort. The image pipeline avoids the width-one validation decode, bounds both target dimensions and validates encoded metadata. Skia remains a compatibility precaution until physical GPU coverage supports removal.

Related Flutter reports [#190640](https://github.com/flutter/flutter/issues/190640) and [#183462](https://github.com/flutter/flutter/issues/183462) concern similar image/blit paths with different triggers; neither alone proves this workload is fixed. The [official Impeller guide](https://docs.flutter.dev/perf/impeller) describes the opt-out.

Before re-enabling Impeller, test a supported stable SDK on physical ARM64 devices, varied GPUs, portrait/landscape images, extreme aspect ratios, 16 KB page-size devices, List/Grid scrolling and detail/zoom, in debug and release. Verify no native aborts and acceptable memory/frame behavior. Use `tool/renderer_probe.dart` only on a disposable emulator or isolated application: `PROBE_MATRIX=true` tests synthetic images; `PROBE_LEGACY=true` intentionally exercises the unsafe legacy trigger. Override with `--enable-impeller` or `--no-enable-impeller`. These targets have no account/network access and are not imported by the app entrypoint.

## Permissions in the release manifest

| Permission | Reason |
| --- | --- |
| INTERNET | Connect to the configured Nextcloud server |
| POST_NOTIFICATIONS | Optional runtime permission for timer alerts |
| VIBRATE | Timer notification vibration according to Android/channel settings |
| RECEIVE_BOOT_COMPLETED | Restore scheduled timer notifications after reboot |
| SCHEDULE_EXACT_ALARM | Optional special access for timely user-created timers |
| org.tecdesigns.cookbook.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION | AndroidX signature-level protection for internal receivers |

There is no storage-wide, camera, location or advertising permission. Backup and cleartext traffic are disabled. Notification delivery and device power policy still need physical acceptance testing.

## Known limits

The API does not provide atomic conditional writes, so simultaneous multi-client edits have a residual race despite preflight checks. Offline access requires previously downloaded content; images may be evicted independently. Uncertain imports/creates may require manual association. Timer delivery is subject to Android permissions and power policy. No compatibility claim substitutes for testing the actual server/device combination.

## Build-tool security

Kotlin Gradle Plugin is pinned to **2.4.20** to address [CVE-2026-53914 / GHSA-r937-wjx7-w2jp](https://github.com/advisories/GHSA-r937-wjx7-w2jp), unsafe deserialization in KAPT incremental cache metadata. The [upstream fix](https://github.com/JetBrains/kotlin/commit/bf51df6) restricts deserialized cache classes. Keep build caches private to a trusted builder; do not restore untrusted contributor caches into a signing environment. CI uses no shared action cache and holds no production key.
