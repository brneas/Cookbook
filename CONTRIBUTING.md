# Contributing to Cookbook

Use Flutter **3.44.6** (Dart **3.12.2**), JDK **21**, Android SDK platform **36**, build-tools **36.0.0**, and NDK **28.2.13676358**. Installation and troubleshooting are in [building](docs/building.md).

Clone your fork using its GitHub clone URL, enter the repository, then run:

```sh
flutter pub get --enforce-lockfile
flutter run
```

Before a pull request:

```sh
dart format --output=none --set-exit-if-changed lib test tool
flutter analyze
flutter test
flutter build apk --debug
```

Use `dart format lib test tool` to apply formatting. Keep `pubspec.lock` committed. Do not upgrade dependencies opportunistically in unrelated changes.

## Changes reviewers can assess

Describe the concrete problem, resulting behavior, tests and any limitations. Keep changes focused. Include synthetic screenshots for visible changes, and reproduction steps for bugs. Do not submit private server data, credentials, generated builds or signing material. Security reports belong in the private reporting process in [SECURITY.md](SECURITY.md).

Read [architecture](docs/architecture.md) and [Nextcloud integration](docs/nextcloud-integration.md) before changing persistence or protocol behavior. Preserve unknown recipe JSON, instruction structures and ordered arrays. Use the external Cookbook API; private `/webapp` routes are not supported client contracts. Do not blindly replay mutations after an unknown response.

For schema changes, increment the database version, add an ordered transactional migration, and test fresh creation plus all supported upgrade paths. Never rewrite a released migration or delete data to recover from a failed upgrade. Update mock protocol, repository and widget coverage for changed behavior. Live tests require a disposable server and explicit opt-in; see building instructions.

UI changes must work with TalkBack, keyboard access, 200% text, light/dark/server colors and phone/tablet layouts. Preserve clear labels, checked/selected semantics and non-gesture alternatives. Test Android lifecycle behavior where timers, browser authentication or secure storage are involved.

## Project scope

This is a native client for existing Nextcloud Cookbook functionality. Shopping-list management, meal planning, AI recipe generation, OCR services and project-owned cloud services are outside scope unless upstream Cookbook changes. Discuss substantial API or architecture changes before implementation.

The project is MIT-licensed. Submit only work you have the right to contribute under that license; retain third-party notices and use independently authored synthetic fixtures.
