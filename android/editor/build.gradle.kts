import java.io.File

plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
    id("maven-publish")
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
    sourceSets.getByName("androidTest").assets.srcDir("../../docs/acceptance/modern-editor/documents")
    buildFeatures { compose = true }
    publishing { singleVariant("release") { withSourcesJar() } }
    compileOptions { sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17 }
}
kotlin { jvmToolchain(17) }
dependencies {
    api(platform("androidx.compose:compose-bom:2025.05.01"))
    api("androidx.compose.foundation:foundation")
    api("androidx.compose.material3:material3")
    androidTestImplementation("androidx.compose.ui:ui-test-junit4")
    debugImplementation("androidx.compose.ui:ui-test-manifest")
    androidTestImplementation("androidx.test:runner:1.6.2")
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
}

// Local preparation only. No credential or remote publishing repository exists.
val deliveryVersion = providers.gradleProperty("modernDeliveryVersion").orNull
val deliveryDirectory = providers.gradleProperty("modernDeliveryDirectory").orNull
if (deliveryVersion != null || deliveryDirectory != null) {
    require(deliveryVersion != null && deliveryDirectory != null) { "Supply both modern delivery properties" }
    require(deliveryVersion.matches(Regex("[0-9]+\\.[0-9]+\\.[0-9]+")) && deliveryVersion != "0.2.0") { "Use a new stable candidate version" }
    require(File(deliveryDirectory).isAbsolute) { "Use an absolute staging directory" }
    require(!file("$deliveryDirectory/studio/seventwo/block-editor/$deliveryVersion/block-editor-$deliveryVersion.aar").exists()) { "Use a fresh candidate destination" }
    require(!providers.gradleProperty("blockEditorTestAbi").isPresent) { "Delivery must contain both supported ABIs" }
    publishing {
        publications {
            create<MavenPublication>("modernRelease") {
                groupId = "studio.seventwo"
                artifactId = "block-editor"
                version = deliveryVersion
                pom {
                    name.set("Block Editor")
                    description.set("Private shared Swift engine and Kotlin/Compose editor candidate")
                    url.set("https://github.com/seventwo-studio/block-editor-internal-packages")
                    licenses { license { name.set("MIT"); url.set("https://opensource.org/license/mit") } }
                }
                afterEvaluate { from(components["release"]) }
            }
        }
        repositories { maven { name = "ModernStaging"; url = file(deliveryDirectory).toURI() } }
    }
}
