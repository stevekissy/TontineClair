import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
    id("com.google.gms.google-services")
}

// ── Lecture du fichier key.properties ─────────────────────────────────────
// Cherche key.properties dans android/ (= rootProject dir).
// Fonctionne sur toute machine (sandbox, Mac, CI) sans chemin codé en dur.
val keyPropertiesFile = rootProject.file("key.properties")
val keyProperties = Properties()
if (keyPropertiesFile.exists()) {
    keyProperties.load(FileInputStream(keyPropertiesFile))
}

// Helpers null-safe : évitent "null cannot be cast to non-null type kotlin.String"
// quand key.properties est absent (première clone, machine sans keystore, CI public).
fun keyProp(key: String): String = (keyProperties[key] as? String)?.trim() ?: ""

android {
    namespace = "com.tontineclair.app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
        isCoreLibraryDesugaringEnabled = true
    }

    // ── Configuration de signature release ────────────────────────────────
    signingConfigs {
        create("release") {
            keyAlias      = keyProp("keyAlias")
            keyPassword   = keyProp("keyPassword")
            storePassword = keyProp("storePassword")
            // storeFile est résolu depuis android/app/ → "../release-key.jks" = android/release-key.jks
            val sf = keyProp("storeFile")
            if (sf.isNotEmpty()) storeFile = file(sf)
        }
    }

    defaultConfig {
        applicationId = "com.tontineclair.app"
        minSdk        = flutter.minSdkVersion
        targetSdk     = flutter.targetSdkVersion
        versionCode   = flutter.versionCode
        versionName   = flutter.versionName
    }

    buildTypes {
        release {
            signingConfig     = signingConfigs.getByName("release")
            isMinifyEnabled   = false
            isShrinkResources = false
        }
    }

    // ── Fix META-INF conflict from smile_id dependencies ──────────────────
    // okhttp3:logging-interceptor:5.3.2 et jspecify:1.0.0 contiennent tous deux
    // META-INF/versions/9/OSGI-INF/MANIFEST.MF → exclude pour éviter le conflit
    packaging {
        resources {
            excludes += "META-INF/versions/9/OSGI-INF/MANIFEST.MF"
            excludes += "META-INF/DEPENDENCIES"
            excludes += "META-INF/LICENSE"
            excludes += "META-INF/LICENSE.txt"
            excludes += "META-INF/NOTICE"
            excludes += "META-INF/NOTICE.txt"
        }
    }
}

flutter {
    source = "../.."
}

// Kotlin 2.3.0 : utiliser compilerOptions DSL à la place de kotlinOptions (déprécié)
tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_11)
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}



























































