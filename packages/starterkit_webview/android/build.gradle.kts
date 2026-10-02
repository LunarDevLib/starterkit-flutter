import com.flutter.gradle.FlutterExtension

group = "dev.lunardev.starterkit.webview"
version = "1.0.0"

plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
}

val flutterExtension = project.extensions.getByType(FlutterExtension::class.java)

android {
    namespace = "dev.lunardev.starterkit.webview"
    compileSdk = flutterExtension.compileSdkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        minSdk = 23
    }
}

dependencies {
    implementation("androidx.webkit:webkit:1.17.1")
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20240303")
}
