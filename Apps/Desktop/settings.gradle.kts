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

rootProject.name = "CloudReaderDesktop"

// Use the shared Android-independent contract/merge module without copying it
// into the desktop source set. Android can adopt the same composite build in
// its D02 integration step.
includeBuild("../../Packages/CloudReaderKotlin") {
    dependencySubstitution {
        substitute(module("io.github.haige120.cloudreader:CloudReaderKotlin"))
            .using(project(":"))
    }
}
