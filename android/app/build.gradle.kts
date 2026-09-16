import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val signingFile = rootProject.file("key.properties")
val signingProperties = Properties().apply {
    if (signingFile.isFile) signingFile.inputStream().use { load(it) }
}
val signingFields = listOf("storeFile", "storePassword", "keyAlias", "keyPassword")
val signingReady = signingFields.all { !signingProperties.getProperty(it).isNullOrBlank() }
val releaseKeystore = signingProperties.getProperty("storeFile", "")

android {
    namespace = "org.tecdesigns.cookbook"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "org.tecdesigns.cookbook"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (signingReady) {
            create("release") {
                storeFile = rootProject.file(releaseKeystore)
                storePassword = signingProperties.getProperty("storePassword")
                keyAlias = signingProperties.getProperty("keyAlias")
                keyPassword = signingProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            // No debug fallback: release artifacts require the maintainer's local identity.
            if (signingReady) signingConfig = signingConfigs.getByName("release")
        }
    }
}

gradle.taskGraph.whenReady {
    if (allTasks.any { Regex("(assemble|bundle|package|sign|validateSigning).*Release").matches(it.name) }) {
        check(signingReady) {
            "Production signing is required. Configure ignored android/key.properties; see docs/releasing.md. Debug signing is not allowed for release."
        }
        check(rootProject.file(releaseKeystore).isFile) { "Production keystore is unavailable." }
        check(!rootProject.file(releaseKeystore).name.equals("debug.keystore", ignoreCase = true) &&
            !signingProperties.getProperty("keyAlias").equals("androiddebugkey", ignoreCase = true)) {
            "Android Debug signing is not allowed for release."
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}

