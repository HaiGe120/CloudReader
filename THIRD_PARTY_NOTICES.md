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

Test-only Kindle and RAR fixtures have separate provenance and retained license texts in `Apps/iOS/CloudReaderTests/KindleFixtures/` and `CBRFixtures/`. The libmobi HUFF/CDIC sample is covered by its retained LGPL-3.0-or-later notice; it is not an app resource or decoder dependency.
