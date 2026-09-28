plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.zhuye.zhu_ye_reader"
    compileSdk = flutter.compileSdkVersion
    // 本工程不含任何原生代码（零平台插件），无需 NDK；
    // 不声明 ndkVersion 可避免 AGP 去拉 700MB 的 NDK 包。
    // ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.zhuye.zhu_ye_reader"
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

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }

    packaging {
        jniLibs {
            // 说明：release 构建会执行 :app:stripReleaseDebugSymbols，用 NDK 的 llvm-strip
            // 把 Flutter 引擎库 libflutter.so 从 ~165MB（含 DWARF）压到 ~11MB。
            // 本机 NDK 28.2.13676358 是手工补的最小可用安装（prebuilt/bin 里放了
            // llvm-strip.exe，来源 dotnet Microsoft.Android.Sdk.Windows 的 binutils）。
            // 若 llvm-strip 不可用，构建会失败——此时可临时启用下面一行跳过 strip，
            // 代价是 APK 会膨胀到 ~166MB：
            // keepDebugSymbols.add("**/*.so")
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
