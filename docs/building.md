# Building and testing

## Toolchain

Use Flutter **3.44.6 stable** with Dart **3.12.2**, JDK **21**, Android SDK platform **36**, build-tools **36.0.0** and NDK **28.2.13676358**. The project uses Gradle **9.1.0**, Android Gradle Plugin **9.0.1**, Kotlin **2.4.20**, and Java/Kotlin bytecode target **17**. The checked-in Gradle wrapper pins its distribution checksum. Use the committed dependency lockfile.

Install Flutter from its [SDK archive](https://docs.flutter.dev/install/archive), configure your SDK/JDK using Flutter and Android tooling, accept Android SDK licenses, and run `flutter doctor -v`. Keep SDK paths in generated, ignored `android/local.properties`; never commit machine-specific paths. PowerShell **7** is required only for the local release tools.

Clone the repository using its GitHub clone URL and run from the project root:

```sh
flutter pub get --enforce-lockfile
flutter run
```

Select an emulator or a USB-debugging device with `flutter devices`. Android 7.0/API 24 is the minimum. The app requires an HTTPS Nextcloud server with Cookbook enabled; unit/widget tests require neither a server nor credentials.

## Verification

```sh
dart format --output=none --set-exit-if-changed lib test tool
flutter analyze
flutter test
flutter build apk --debug
```

`dart format lib test tool` applies formatting. The debug APK is under `build/app/outputs/flutter-apk/`. It is for development, not publication. Production release builds intentionally fail without local signing; see [releasing](releasing.md).

Tests use mock HTTP and in-memory SQLite, covering authentication, migration, synchronization, conflict recovery, schema preservation, Cooking and responsive/accessibility layouts. Two live tests skip when credentials are absent. To opt in, supply `NEXTCLOUD_TEST_SERVER`, `NEXTCLOUD_TEST_USERNAME` and `NEXTCLOUD_TEST_APP_PASSWORD` through a private local process environment. Use a disposable account. `NEXTCLOUD_TEST_ALLOW_WRITES=true` additionally enables owned-fixture create/update/delete testing. Do not configure these in public CI or put values in shell history.

Synthetic screenshot tests can export captures when `COOKBOOK_VISUAL_DIR` points to an ignored local directory. Optional `COOKBOOK_VISUAL_FONT` and `COOKBOOK_VISUAL_ICONS` point to locally installed Roboto and Material Icons fonts. They are not required for tests or normal builds. Keep synthetic screenshots only when useful to a review.

## Repeatability

The pinned SDK, lockfile, wrapper and documented toolchain reproduce the supported build procedure. This is not a claim of bit-for-bit reproducible signed APKs across operating systems: signing, ZIP metadata and tool downloads may differ. Verify the certificate, manifest and hash of the actual release artifact. CI compiles debug builds without production credentials.
