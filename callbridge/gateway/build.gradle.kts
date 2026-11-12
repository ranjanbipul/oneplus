plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "com.antigravity.callbridge.gateway"
    compileSdk = 34

    defaultConfig {
        applicationId = "com.antigravity.callbridge.gateway"
        minSdk = 33
        // 33 on purpose: matches the OnePlus 8 (Android 13) and avoids API 34 foreground-service-type rules.
        targetSdk = 33
        versionCode = 8
        versionName = "0.2"
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            signingConfig = signingConfigs.getByName("debug")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = "17"
    }
    lint {
        // Privileged permissions are intentional: this app is installed as a priv-app via Magisk.
        disable += "ProtectedPermissions"
        checkReleaseBuilds = false
    }
}

dependencies {
    implementation(project(":proto"))
}
