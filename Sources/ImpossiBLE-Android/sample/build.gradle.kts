plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

repositories {
    mavenCentral()
    google()
}

android {
    namespace = "com.impossible.sample"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.impossible.sample"
        minSdk = 29
        targetSdk = 36
        versionCode = 1
        versionName = "1.0"
        // The relay token is read from -PimpossibleToken=<token> and baked into the APK: never upload it.
        manifestPlaceholders["impossibleToken"] = (project.findProperty("impossibleToken") as String?).orEmpty()
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}

dependencies {
    implementation(project(":shim"))
}
