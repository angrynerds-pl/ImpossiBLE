buildscript {
    repositories {
        mavenCentral()
        google()
    }
    dependencies {
        classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:2.1.10")
        classpath("com.android.tools.build:gradle:8.11.1")
    }
}

val libraryVersion = Regex("""CLIENT_VERSION\s*=\s*"([^"]+)"""")
    .find(file("core/src/main/kotlin/com/impossible/ble/core/Wire.kt").readText())!!.groupValues[1]

allprojects {
    group = "com.impossible"
    version = libraryVersion
}
