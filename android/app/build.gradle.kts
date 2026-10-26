import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Store builds (RuStore, Google Play) are signed with the release key whose properties file is named
// by BUDGET_STORE_KEY (kept outside the repository). Without it builds are signed with the debug key,
// so they install over the APKs already on phones.
val storeKey = System.getenv("BUDGET_STORE_KEY")?.let { file(it) }?.takeIf { it.exists() }?.let { f ->
    Properties().apply { f.inputStream().use { load(it) } }
}

android {
    namespace = "app.budget.budget_app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // The store id. The Kotlin package (namespace) keeps its old name: nobody sees it.
        applicationId = "app.saldo"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // Phones only: SQLCipher's x86 emulator libraries would add ~6 MB for nothing.
    packaging {
        jniLibs {
            excludes += listOf("lib/x86/**", "lib/x86_64/**")
        }
    }

    signingConfigs {
        if (storeKey != null) {
            create("store") {
                storeFile = file(storeKey.getProperty("storeFile"))
                storePassword = storeKey.getProperty("storePassword")
                keyAlias = storeKey.getProperty("keyAlias")
                keyPassword = storeKey.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (storeKey != null) signingConfigs.getByName("store") else signingConfigs.getByName("debug")
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
    implementation("androidx.documentfile:documentfile:1.0.1")
    // AppCompat themes: the biometric prompt of the app lock crashes on Android 8 and older without them.
    implementation("androidx.appcompat:appcompat:1.7.0")
    // Text of PDF bank statements (Sber, VTB), read on the phone.
    implementation("com.tom-roush:pdfbox-android:2.0.27.0")
    // Text of a shared payment screenshot, read on the phone (Chinese and Latin script). The model
    // comes through Google Play services (downloaded once, see the manifest): the APK stays small.
    implementation("com.google.android.gms:play-services-mlkit-text-recognition-chinese:16.0.1")
    // QR codes of receipts (Russian ones carry the total and the time).
    implementation("com.google.android.gms:play-services-mlkit-barcode-scanning:18.3.1")
    testImplementation("junit:junit:4.13.2")
}
