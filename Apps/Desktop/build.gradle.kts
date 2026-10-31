import java.util.Properties
import java.time.Duration

plugins {
    kotlin("jvm") version "2.4.20"
    id("org.jetbrains.compose") version "1.9.0"
    id("org.jetbrains.kotlin.plugin.compose") version "2.4.20"
}

group = "io.github.haige120.cloudreader"
val coordinatedRelease = Properties().apply {
    rootProject.file("../../release.properties").inputStream().use { load(it) }
}
version = coordinatedRelease.getProperty("version")

val os = System.getProperty("os.name").lowercase()
val arm = System.getProperty("os.arch") in listOf("aarch64", "arm64")
val javafxPlatform = when {
    os.contains("win") -> "win"
    os.contains("mac") -> if (arm) "mac-aarch64" else "mac"
    else -> if (arm) "linux-aarch64" else "linux"
}

dependencies {
    implementation("io.github.haige120.cloudreader:CloudReaderKotlin:1.0.0-SNAPSHOT")
    implementation(compose.desktop.currentOs)
    implementation(compose.material)
    implementation(compose.material3)
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-swing:1.10.2")
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.9.0")
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    implementation("com.github.mwiede:jsch:2.27.3")
    implementation("org.bouncycastle:bcprov-jdk18on:1.83")
    implementation("org.apache.pdfbox:pdfbox:3.0.6")
    implementation("org.jsoup:jsoup:1.23.2")
    listOf("base", "graphics", "controls", "media", "web", "swing").forEach {
        implementation("org.openjfx:javafx-$it:21.0.9:$javafxPlatform")
    }
    testImplementation("junit:junit:4.13.2")
}

kotlin {
    jvmToolchain(17)
    sourceSets.main { kotlin.srcDir("../../Packages/CloudReaderUI/src/main/kotlin") }
}

tasks.test {
    useJUnit()
    timeout.set(Duration.ofMinutes(5))
}

tasks.processResources {
    from("../Android/app/src/main/assets/CloudReader_Field_Guide.txt")
    from("../../THIRD_PARTY_NOTICES.md")
}

compose.desktop {
    application {
        mainClass = "io.github.haige120.cloudreader.desktop.MainKt"
        nativeDistributions {
            packageName = "CloudReader"
            packageVersion = coordinatedRelease.getProperty("version")
            description = "CloudReader offline library and reader"
            modules("java.sql", "jdk.unsupported", "jdk.unsupported.desktop", "jdk.jsobject", "jdk.xml.dom", "java.net.http", "java.xml", "java.desktop", "java.logging", "jdk.charsets", "jdk.crypto.ec", "java.naming", "java.security.jgss")
            windows {
                upgradeUuid = "7359bd1a-f774-4b97-81b0-971592bf6d72"
                fileAssociation("application/epub+zip", "epub", "EPUB book")
                fileAssociation("application/pdf", "pdf", "PDF book")
                fileAssociation("text/plain", "txt", "Text book")
                fileAssociation("application/x-fictionbook+xml", "fb2", "FictionBook")
                fileAssociation("application/vnd.comicbook+zip", "cbz", "Comic book")
            }
            linux {
                shortcut = true
                appCategory = "Office"
                menuGroup = "Office"
                iconFile.set(project.file("../Android/app/src/main/res/drawable-nodpi/cloudreader_icon.png"))
                fileAssociation("application/epub+zip", "epub", "EPUB book")
                fileAssociation("application/pdf", "pdf", "PDF book")
                fileAssociation("text/plain", "txt", "Text book")
                fileAssociation("application/x-fictionbook+xml", "fb2", "FictionBook")
                fileAssociation("application/vnd.comicbook+zip", "cbz", "Comic book")
            }
            targetFormats(
                org.jetbrains.compose.desktop.application.dsl.TargetFormat.Msi,
                org.jetbrains.compose.desktop.application.dsl.TargetFormat.Deb,
            )
        }
    }
}
