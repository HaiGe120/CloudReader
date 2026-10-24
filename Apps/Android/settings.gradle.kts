pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "CloudReader"
include(":app")

// Shared Android-independent contract/merge/assistant module for the desktop
// client and Android. Platform adapters remain in :app.
includeBuild("../../Packages/CloudReaderKotlin") {
    dependencySubstitution {
        substitute(module("io.github.haige120.cloudreader:CloudReaderKotlin"))
            .using(project(":"))
    }
}
