plugins {
    kotlin("jvm") version "2.4.20"
    kotlin("plugin.serialization") version "2.4.20"
}

group = "io.github.haige120.cloudreader"
version = "1.0.0-SNAPSHOT"


kotlin {
    jvmToolchain(17)
    sourceSets.all {
        // Preserve historical conflict copies without compiling duplicate declarations.
        kotlin.exclude("**/* 2.kt")
    }
}

dependencies {
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.9.0")
    implementation("org.jsoup:jsoup:1.23.2")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.10.2")
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    testImplementation("junit:junit:4.13.2")
}

tasks.test {
    useJUnit()
}
