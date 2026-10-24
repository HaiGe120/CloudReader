# CloudReader Desktop feasibility client

This is the bounded D01/D03.a prototype for a shared Kotlin/JVM desktop client using Compose Multiplatform Desktop. It is intentionally small and buildable on a JVM 17 toolchain:

```sh
./gradlew test
./gradlew run
```

The prototype imports a copy of local `.txt` files into `~/.cloudreader-desktop`, restores a UTF-16 text offset after relaunch, and exposes the seams needed by the future desktop slices:

- `LibraryRepository` owns durable local metadata and imported content.
- `ContentReader` is the format reader boundary. `TxtContentReader` is implemented; PDF and EPUB remain visible as unsupported.
- `FilePicker` and `DropTarget` isolate native picker/drop behavior.
- `CredentialStore` requires an OS credential adapter. The app does not write secrets by default; the current desktop entry point reports OS credential storage as unavailable. A separately named plaintext adapter can be enabled explicitly when no supported OS secret service is available, after Settings discloses the tradeoff.

PDF/EPUB engines, provider sync, local-store migration to portable manifests, accessibility verification on Windows/Linux, OS credential vaults, drag and drop, packaging, and release support are future work. This prototype does not claim those features.

The current implementation uses a private properties metadata format only to make the local resume path inspectable. The shared Kotlin contract is now available for D02/D04 integration; the local storage migration and portable manifest mapping must be reviewed before cross-device use.

The Gradle project includes `Packages/CloudReaderKotlin` as a composite build and
has a smoke test through the shared v1 object-name codec. The local metadata
adapter remains intentionally separate from portable records until the storage
and migration boundary is reviewed.
