plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}
android {
    namespace = "studio.seventwo.blockeditor"
    compileSdk = 35
    defaultConfig {
        minSdk = 26
        targetSdk = 35
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        ndk {
            val testAbi = providers.gradleProperty("blockEditorTestAbi").orNull
            require(testAbi == null || testAbi in listOf("arm64-v8a", "x86_64")) { "Unsupported blockEditorTestAbi" }
            abiFilters += testAbi?.let { listOf(it) } ?: listOf("arm64-v8a", "x86_64")
        }
    }
    sourceSets.getByName("androidTest").assets.srcDir("../../tests/BlockEditorCoreTests/Fixtures")
    sourceSets.getByName("androidTest").assets.srcDir("../../benchmarks")
    buildFeatures { compose = true }
    compileOptions { sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17 }
}
kotlin { jvmToolchain(17) }
dependencies {
    implementation(platform("androidx.compose:compose-bom:2025.05.01"))
    implementation("androidx.compose.foundation:foundation")
    implementation("androidx.compose.material3:material3")
    androidTestImplementation("androidx.compose.ui:ui-test-junit4")
    debugImplementation("androidx.compose.ui:ui-test-manifest")
    androidTestImplementation("androidx.test:runner:1.6.2")
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
}
