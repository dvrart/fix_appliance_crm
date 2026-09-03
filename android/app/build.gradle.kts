import java.util.Properties

// Реквизиты релизного ключа. Сам файл ключа лежит вне репозитория (~/keys),
// key.properties в .gitignore. Если файла нет — собираем отладочной подписью,
// чтобы сборка не падала у того, у кого ключа нет.
val keystoreProperties = Properties().apply {
    val file = rootProject.file("key.properties")
    // Читаем как UTF-8: load(InputStream) разбирает файл в ISO-8859-1 и портит
    // путь, если в нём есть не-латиница (например, кириллица в имени
    // пользователя Windows). Тогда ключ «не находится» и релиз молча уходит
    // с отладочной подписью.
    if (file.exists()) file.reader(Charsets.UTF_8).use { load(it) }
}
val releaseKeyPath = keystoreProperties.getProperty("storeFile")
val hasReleaseKey = releaseKeyPath?.let { file(it).exists() } == true
if (releaseKeyPath != null && !hasReleaseKey) {
    logger.warn("Релизный ключ не найден по пути $releaseKeyPath")
}

plugins {
    id("com.android.application")
    // START: FlutterFire Configuration
    id("com.google.gms.google-services")
    // END: FlutterFire Configuration
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.fix_appliance_crm"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    packaging {
        resources {
            pickFirsts += setOf(
                "org/bouncycastle/x509/CertPathReviewerMessages.properties",
                "org/bouncycastle/x509/CertPathReviewerMessages_de.properties",
            )
        }
    }

    sourceSets {
        getByName("main") {
            assets.srcDirs("src/main/assets", "../../assets/appliances")
        }
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.example.fix_appliance_crm"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // Twilio Voice SDK требует minSdk 26 (Android 8.0)
        minSdk = maxOf(flutter.minSdkVersion, 26)
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        multiDexEnabled = true
    }

    signingConfigs {
        if (hasReleaseKey) {
            create("release") {
                storeFile = file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            // Отладочным ключом релиз подписывать нельзя: такую сборку не примет
            // Google Play, а при смене ключа на машине приложение перестанет
            // обновляться поверх установленного.
            signingConfig = if (hasReleaseKey) {
                signingConfigs.getByName("release")
            } else {
                logger.warn("key.properties не найден — релиз подписан отладочным ключом")
                signingConfigs.getByName("debug")
            }
            // Правила для Twilio Voice SDK — используются, если включите minifyEnabled.
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
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

configurations.all {
    exclude(group = "org.bouncycastle", module = "bcprov-jdk15to18")
}
