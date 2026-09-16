# Third-party notices and provenance

MIT applies to this project's independently authored code, not its dependencies. Full dependency license texts are collected in [THIRD_PARTY_LICENSES.txt](THIRD_PARTY_LICENSES.txt); the application also exposes Flutter's license registry in Settings. Preserve these notices when distributing source or binaries. Flutter test/web plugin SDK packages share the Flutter SDK license.

## Application sources and artwork

The Nextcloud integration is independently implemented from public protocol contracts and observed behavior. No upstream AGPL Cookbook implementation, generated API schema, recipe fixture or screenshot is included. Cloud Tasks (GPL) was a behavioral reference for Login Flow v2; its source is not included in this project. Protocol similarity is not a source-code license grant. Contributions must preserve this separation.

Recipe fixtures and screenshot content are independently authored synthetic examples, not exported accounts. The launcher is original vector open-book geometry; it does not use the Nextcloud cloud logo. Renderer fixtures are synthetic solid-color images. Material icons and Flutter/Android scaffolding retain their original licenses. Unused scaffold launcher PNGs are not distributed in this source tree.

## Android and build components

AndroidX, the Android Gradle plugin, Gradle wrapper and related Android tooling carry their upstream Apache/BSD notices. Java core-library desugaring uses `com.android.tools:desugar_jdk_libs:2.1.4`, a subset of OpenJDK under **GPLv2 with the Classpath Exception**, as declared by its Maven POM. The license and additional exception text are retained unchanged. This is a dependency license, not copied upstream Cookbook application code, and does not replace this project's MIT license. Its [published source and licensing](https://github.com/google/desugar_jdk_libs) remain available upstream.

The Flutter engine contains additional third-party code and notices included in the SDK's sky_engine license. The locked Pub packages below include runtime, platform-specific and test/build dependencies; not all are shipped on Android. Exact dependency versions and hashes are in pubspec.lock; the Gradle wrapper pins its downloaded distribution checksum.

## Locked SDK / Pub component attribution

- Flutter SDK
- args
- async
- boolean_selector
- characters
- clock
- code_assets
- collection
- crypto
- dbus
- diacritic
- dio
- dio_web_adapter
- fake_async
- ffi
- ffi_leak_tracker
- file
- fixnum
- flutter
- flutter_lints
- flutter_local_notifications
- flutter_local_notifications_linux
- flutter_local_notifications_platform_interface
- flutter_local_notifications_web
- flutter_local_notifications_windows
- flutter_markdown_plus
- flutter_riverpod
- flutter_secure_storage
- flutter_secure_storage_darwin
- flutter_secure_storage_linux
- flutter_secure_storage_platform_interface
- flutter_secure_storage_web
- flutter_secure_storage_windows
- glob
- go_router
- hooks
- http
- http_parser
- jni
- jni_flutter
- jni_util
- leak_tracker
- leak_tracker_flutter_testing
- leak_tracker_testing
- lints
- listen
- logging
- markdown
- matcher
- material_color_utilities
- meta
- mime
- native_toolchain_c
- objective_c
- package_config
- package_info_plus
- package_info_plus_platform_interface
- path
- path_provider
- path_provider_android
- path_provider_foundation
- path_provider_linux
- path_provider_platform_interface
- path_provider_windows
- petitparser
- platform
- plugin_platform_interface
- pub_semver
- record_use
- riverpod
- sky_engine
- source_span
- sqflite
- sqflite_android
- sqflite_common
- sqflite_common_ffi
- sqflite_darwin
- sqflite_platform_interface
- sqlite3
- stack_trace
- state_notifier
- stream_channel
- string_scanner
- synchronized
- term_glyph
- test_api
- timezone
- typed_data
- url_launcher
- url_launcher_android
- url_launcher_ios
- url_launcher_linux
- url_launcher_macos
- url_launcher_platform_interface
- url_launcher_web
- url_launcher_windows
- uuid
- vector_math
- vm_service
- wakelock_plus
- wakelock_plus_platform_interface
- web
- win32
- xdg_directories
- xml
- yaml
