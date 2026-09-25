import java.util.Base64
import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Flutter forwards --dart-define values as a comma-separated Base64 list.
// Derive the Android identity from the same flag as Dart, so local sessions
// and purchases remain inside the existing, separate test application.
val pulsoDartDefines = providers.gradleProperty("dart-defines").orNull
    ?.split(',')
    ?.filter { it.isNotEmpty() }
    ?.map { String(Base64.getDecoder().decode(it), Charsets.UTF_8) }
    ?.associate { define ->
        val parts = define.split('=', limit = 2)
        require(parts.size == 2) { "Invalid Flutter dart-define format" }
        parts[0] to parts[1]
    }
    ?: emptyMap()
val pulsoLocalFlag = pulsoDartDefines["PULSO_LOCAL_TEST"]
require(pulsoLocalFlag == null || pulsoLocalFlag in setOf("true", "false")) {
    "PULSO_LOCAL_TEST must be true or false"
}
val pulsoLocalTest = pulsoLocalFlag == "true"
// Explicit source-distribution build. Default production signing remains required.
val fdroidUnsignedFlag = providers.gradleProperty("fdroidUnsigned")
    .orElse(providers.environmentVariable("ORG_GRADLE_PROJECT_fdroidUnsigned"))
    .orNull
require(fdroidUnsignedFlag == null || fdroidUnsignedFlag in setOf("true", "false")) {
    "fdroidUnsigned must be true or false"
}
val fdroidUnsigned = fdroidUnsignedFlag == "true"
require(!fdroidUnsigned || !pulsoLocalTest) {
    "fdroidUnsigned must use the production app identity, not a local-test build"
}
val pulsoSigningFile = file(
    System.getenv("PULSO_SIGNING_PROPERTIES")
        ?: "${System.getProperty("user.home")}/.android/pulso-libre-release/signing.properties"
)
val pulsoSigning = Properties().apply {
    if (!fdroidUnsigned && pulsoSigningFile.isFile) pulsoSigningFile.inputStream().use { load(it) }
}
if (!pulsoLocalTest && !fdroidUnsigned && gradle.startParameter.taskNames.any { it.contains("release", ignoreCase = true) }) {
    require(pulsoSigningFile.isFile) { "The private Pulso Libre release signing configuration is required" }
}

android {
    namespace = "com.example.pulso_libre_app"
    compileSdk = 37
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = if (pulsoLocalTest) {
            "ar.com.pllabs.pulsolibre.flujov2"
        } else {
            "ar.com.pllabs.pulsolibre"
        }
        manifestPlaceholders["pulsoAppName"] =
            if (pulsoLocalTest) "Pulso Libre - Pruebas" else "Pulso Libre"
        manifestPlaceholders["pulsoDebugCleartext"] = pulsoLocalTest.toString()
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (!fdroidUnsigned && pulsoSigningFile.isFile) {
            create("pulsoRelease") {
                storeFile = file(pulsoSigning.getProperty("storeFile"))
                storePassword = pulsoSigning.getProperty("storePassword")
                keyAlias = pulsoSigning.getProperty("keyAlias")
                keyPassword = pulsoSigning.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (fdroidUnsigned) {
                null
            } else if (pulsoLocalTest) {
                signingConfigs.getByName("debug")
            } else {
                signingConfigs.findByName("pulsoRelease")
            }
        }
    }
}

flutter {
    source = "../.."
}

