import com.flutter.gradle.FlutterExtension

group = "dev.lunardev.starterkit.preferences"
version = "1.0.0"

plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
}

val flutterExtension = project.extensions.getByType(FlutterExtension::class.java)

android {
    namespace = "dev.lunardev.starterkit.preferences"
    compileSdk = flutterExtension.compileSdkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions { jvmTarget = JavaVersion.VERSION_17.toString() }

    defaultConfig { minSdk = 23 }
}

dependencies {
    testImplementation("junit:junit:4.13.2")
}
