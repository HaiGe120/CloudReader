# Third-party notices

The Apple apps use Apple frameworks and the following open-source libraries for native SFTP transport and book preparation. Their complete license terms are bundled with both Apple apps in `THIRD_PARTY_NOTICES.txt`; the corresponding source copies are retained in [`ThirdPartyLicenses/`](ThirdPartyLicenses/).

- [ZIPFoundation 0.9.20](https://github.com/weichsel/ZIPFoundation), MIT License (Apple EPUB and comic preparation).
- [Foliate-js](https://github.com/johnfactotum/foliate-js/tree/78914aef4466eb960965702401634c2cb348e9b1) at revision `78914aef4466eb960965702401634c2cb348e9b1` and [fflate 0.8.2](https://github.com/101arrowz/fflate), MIT licenses (offline Apple MOBI/AZW3 decoder; only `mobi.js` and the `unzlibSync` implementation are bundled). Full license texts and source notices are included in the decoder resource `Apps/Shared/KindleDecoder/NOTICE.txt` and retained in `ThirdPartyLicenses/Foliate-js-MIT.txt` and `ThirdPartyLicenses/fflate-MIT.txt`.
- [Citadel 0.12.1](https://github.com/orlandos-nl/Citadel), MIT License.
- [SwiftNIO SSH 0.3.7](https://github.com/Wellz26/swift-nio-ssh), Apache License 2.0.
- [SwiftNIO 2.104.0](https://github.com/apple/swift-nio), Apache License 2.0.
- [Swift Crypto 3.15.1](https://github.com/apple/swift-crypto), Apache License 2.0.
- [Swift Log 1.16.1](https://github.com/apple/swift-log), Apache License 2.0.
- [Swift Atomics 1.3.1](https://github.com/apple/swift-atomics), Apache License 2.0.
- [Swift Collections 1.7.3](https://github.com/apple/swift-collections), Apache License 2.0.
- [Swift ASN.1 1.7.3](https://github.com/apple/swift-asn1), Apache License 2.0.
- [Swift System 1.8.1](https://github.com/apple/swift-system), Apache License 2.0.
- [BigInt 5.7.0](https://github.com/attaswift/BigInt), MIT License.
- [Unrar.swift 0.5.4](https://github.com/mtgto/Unrar.swift/tree/7216007a38ac122dbdeae26cfdaf7f10775c868f), MIT License for the Swift wrapper. The included UnRAR C++ source is covered by Alexander Roshal's UnRAR license, which permits archive handling but prohibits use to develop a RAR-compatible archiver; license, source notice and acknowledgements are retained in `ThirdPartyLicenses/UnrarSwift/`.

Exact dependency revisions are pinned in each Apple project's `project.xcworkspace/xcshareddata/swiftpm/Package.resolved`.

Retained Kotlin/desktop upstream license and attribution copies are in
[`ThirdPartyLicenses/KotlinDesktop/`](ThirdPartyLicenses/KotlinDesktop/), with
repository/ref/path provenance. These copies supplement, not replace, notices
already carried by upstream artifacts and the binary distribution companion.

The Android, Windows and Linux clients also use the following dependencies. Their
upstream artifacts retain their license and third-party notices; desktop packages
include this notice file alongside the application resources.

- [Compose Multiplatform 1.9.0](https://github.com/JetBrains/compose-multiplatform), Apache License 2.0; Android uses AndroidX Compose under Apache License 2.0.
- [Kotlin](https://github.com/JetBrains/kotlin), Kotlin coroutines and serialization, Apache License 2.0.
- [jsoup 1.23.2](https://jsoup.org/), MIT License; shared safe EPUB/FB2 preparation.
- [OpenJFX 21.0.9](https://github.com/openjdk/jfx21u/tree/21.0.9%2B1), GPL version 2 with the Classpath Exception and retained third-party terms; desktop WebKit rendering. The unified release supplies the matching `21.0.9+1` source archive and upstream legal files alongside the binaries.
- [Eclipse Temurin 17.0.20+8](https://github.com/adoptium/temurin17-binaries/releases/tag/jdk-17.0.20%2B8), the bundled desktop Java runtime: GPL version 2 with the Classpath Exception and additional retained notices. Matching source is supplied with the unified release; each runtime retains its `legal/` directory.
- [Skiko 0.9.22.2](https://github.com/JetBrains/skiko/tree/v0.9.22.2), Apache License 2.0, including its retained NOTICE and Skia/native third-party terms. Compose uses Skiko for desktop graphics.
- [Apache PDFBox 3.0.6](https://pdfbox.apache.org/), Apache License 2.0; desktop PDF rendering and text extraction.
- [OkHttp 4.12.0](https://github.com/square/okhttp), Apache License 2.0.
- [mwiede JSch 2.27.3](https://github.com/mwiede/jsch), BSD-3-Clause; [Bouncy Castle 1.83](https://www.bouncycastle.org/), Bouncy Castle License (MIT style).
- Android additionally retains [Readium Kotlin Toolkit 3.4.0](https://github.com/readium/kotlin-toolkit), BSD-3-Clause, and AndroidX PDF, Room, Lifecycle, DataStore and Window libraries under Apache License 2.0. Google Play services authorization remains subject to Google's SDK terms.

Test-only Kindle and RAR fixtures have separate provenance and retained license texts in `Apps/iOS/CloudReaderTests/KindleFixtures/` and `CBRFixtures/`. The libmobi HUFF/CDIC sample is covered by its retained LGPL-3.0-or-later notice; it is not an app resource or decoder dependency.

## Binary distribution companion

The `v1.2.0-unified-preview` release includes
`CloudReader-1.2.0-third-party-notices.zip`, containing retained notices from the
actual APK/desktop dependencies, Maven license metadata, runtime legal files and
upstream attributions. The all-app bundle includes that companion; keep it with
individual-package redistributions. Matching Java/OpenJFX source archives are
separate assets in the same release. The project's MIT license applies to
CloudReader's original code, not all bundled dependencies or platform SDKs.
