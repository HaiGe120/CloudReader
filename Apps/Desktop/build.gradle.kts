plugins {
    kotlin("jvm") version "2.4.20"
    id("org.jetbrains.compose") version "1.9.0"
    id("org.jetbrains.kotlin.plugin.compose") version "2.4.20"
}

group = "io.github.haige120.cloudreader"
version = "0.1.0"

dependencies {
    implementation("io.github.haige120.cloudreader:CloudReaderKotlin:1.0.0-SNAPSHOT")
    implementation(compose.desktop.currentOs)
    implementation(compose.material)
    testImplementation("junit:junit:4.13.2")
}

kotlin {
    jvmToolchain(17)
}

tasks.test {
    useJUnit()
}

compose.desktop {
    application {
        mainClass = "io.github.haige120.cloudreader.desktop.MainKt"
        nativeDistributions {
            packageName = "CloudReader"
            packageVersion = "0.1.0"
            description = "CloudReader desktop feasibility client"
            targetFormats(
                org.jetbrains.compose.desktop.application.dsl.TargetFormat.Msi,
                org.jetbrains.compose.desktop.application.dsl.TargetFormat.Deb,
            )
        }
    }
}
