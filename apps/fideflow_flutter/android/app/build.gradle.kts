plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing material is provided by the local environment or CI secrets.
// GitHub Actions should write the shared keystore to the configured path for the
// duration of the release job and remove it after packaging.
fun signingInput(name: String): String? =
    providers.gradleProperty(name).orElse(providers.environmentVariable(name)).orNull

val releaseKeystorePath = signingInput("FIDEFLOW_ANDROID_KEYSTORE_PATH")
    ?: "../fideflow-android.jks"
val releaseKeystorePassword = signingInput("FIDEFLOW_ANDROID_KEYSTORE_PASSWORD")
val releaseKeyAlias = signingInput("FIDEFLOW_ANDROID_KEY_ALIAS") ?: "fideflow-android"
val releaseKeyPassword = signingInput("FIDEFLOW_ANDROID_KEY_PASSWORD")
val releaseVariantRequested = gradle.startParameter.taskNames.any {
    it.contains("release", ignoreCase = true)
}

if (releaseVariantRequested) {
    require(!releaseKeystorePassword.isNullOrBlank()) {
        "Set FIDEFLOW_ANDROID_KEYSTORE_PASSWORD through a Gradle property or environment variable."
    }
    require(!releaseKeyPassword.isNullOrBlank()) {
        "Set FIDEFLOW_ANDROID_KEY_PASSWORD through a Gradle property or environment variable."
    }
    require(file(releaseKeystorePath).isFile) {
        "Release keystore not found at '$releaseKeystorePath'; provide FIDEFLOW_ANDROID_KEYSTORE_PATH."
    }
}

android {
    namespace = "com.moetaku.fideflow"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = "28.2.13676358"
    sourceSets.getByName("main").assets.srcDir("../../../../native/build/mobile/android/assets")
    sourceSets.getByName("main").jniLibs.srcDir("../../../../native/build/mobile/android/jniLibs")

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.moetaku.fideflow"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 24
        ndk { abiFilters.addAll(listOf("arm64-v8a", "x86_64")) }
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("shared") {
            keyAlias = releaseKeyAlias
            keyPassword = releaseKeyPassword.orEmpty()
            storeFile = file(releaseKeystorePath)
            storePassword = releaseKeystorePassword.orEmpty()
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("shared")
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

val refreshNativeAudio by tasks.registering(Exec::class) {
    commandLine(
        "python3",
        file("../../../../tooling/native/mobile/build.py").absolutePath,
        "refresh",
        "--platform",
        "android",
    )
}
tasks.named("preBuild") { dependsOn(refreshNativeAudio) }
