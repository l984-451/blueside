plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.plugin.compose")
    id("org.jetbrains.kotlin.plugin.serialization")
}

val testPacks = listOf("test-*", "*-test.sqlite", "nav-tiles.pmtiles", "nav-vfr.pmtiles")
val shipped = tasks.register<Sync>("shippedAssets") {
    from("../../ios/MapAssets") { exclude(testPacks) }
    into(layout.buildDirectory.dir("shippedAssets"))
}
tasks.named("preBuild") { dependsOn(shipped) }

android {
    namespace = "com.gstudios.blueside"
    compileSdk = 37
    ndkVersion = "30.0.16248370"

    defaultConfig {
        applicationId = "com.gstudios.blueside"
        minSdk = 31
        targetSdk = 36
        versionCode = 1
        versionName = "0.1"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        ndk { abiFilters += "arm64-v8a" }
    }
    buildFeatures { compose = true }
    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            // ponytail: debug-signed so it installs for checks; a real key comes with store release.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    // Styles, glyphs and sprites shared with iOS. Release leaves out the test packs.
    sourceSets["main"].assets.directories.add(layout.buildDirectory.dir("shippedAssets").get().asFile.path)
    // Debug adds the test packs and the pipeline's manifest fixture for the launch hooks and device tests.
    sourceSets["debug"].assets.directories.add("../../ios/MapAssets")
    sourceSets["debug"].assets.directories.add("../../pipeline/tests/fixtures")
    // Golden JSON written by the Swift bridge tests.
    sourceSets["test"].resources.directories.add("../swift/Tests/BluesideJNITests/Fixtures")
}

dependencies {
    implementation(platform("androidx.compose:compose-bom:2026.09.00"))
    // Pinned over the BOM for the Expressive components.
    implementation("androidx.compose.material3:material3:1.5.0-beta01")
    implementation("androidx.activity:activity-compose:1.13.0")
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.11.0")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.10.0")
    implementation("androidx.compose.material3.adaptive:adaptive-layout:1.3.0")
    implementation("androidx.compose.material3.adaptive:adaptive-navigation:1.3.0")
    implementation("androidx.compose.material:material-icons-extended:1.7.8")
    implementation("org.maplibre.gl:android-sdk:13.6.1")
    testImplementation("junit:junit:4.13.2")
    androidTestImplementation("androidx.test.ext:junit:1.3.0")
    androidTestImplementation("androidx.test:runner:1.7.0")
    androidTestImplementation(platform("androidx.compose:compose-bom:2026.09.00"))
    androidTestImplementation("androidx.compose.ui:ui-test-junit4")
    debugImplementation("androidx.compose.ui:ui-test-manifest")
}
