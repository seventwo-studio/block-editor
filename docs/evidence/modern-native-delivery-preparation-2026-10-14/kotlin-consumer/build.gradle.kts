plugins { id("com.android.library") version "8.10.1"; id("org.jetbrains.kotlin.android") version "2.1.21"; id("org.jetbrains.kotlin.plugin.compose") version "2.1.21" }
android { namespace = "smoke.nativeconsumer"; compileSdk = 35; defaultConfig { minSdk = 26 }; buildFeatures { compose = true }; compileOptions { sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17 } }
kotlin { jvmToolchain(17) }
dependencies { implementation("studio.seventwo:block-editor:0.2.1") }
