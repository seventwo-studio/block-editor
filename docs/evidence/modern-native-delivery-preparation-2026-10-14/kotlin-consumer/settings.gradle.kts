pluginManagement { repositories { google(); mavenCentral(); gradlePluginPortal() } }
dependencyResolutionManagement { repositories { maven { url = uri("file:///private/tmp/modern-native-maven-0.2.1-d932073"); content { includeModule("studio.seventwo", "block-editor") } }; google(); mavenCentral() } }
rootProject.name = "NativeArtifactConsumer"
