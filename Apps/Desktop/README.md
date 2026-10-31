# CloudReader for Windows and Linux

The desktop app shares its library/navigation, assistant UI, portable values,
merge rules, AI transport and EPUB/FB2/CBZ preparation with Android. Native hosts
provide file access, credential storage, PDF rendering and WebKit. The current
reader scope follows the enabled iOS readers: TXT, PDF, EPUB, FB2 and CBZ.
MOBI/AZW3/CBR remain importable storage-only formats.

The existing library at `~/.cloudreader-desktop` is retained, including prototype
properties files and UTF-16 TXT offsets. Original imported files are copied. New
metadata writes are staged, deletion records are durable, and credentials stay
outside portable manifests. `CLOUDREADER_DESKTOP_HOME` selects a separate library
for test and development runs.

## Build

Use JDK 17 (Temurin is recommended for packaging). From the repository root:

```sh
./Packages/CloudReaderKotlin/gradlew -p Apps/Desktop test
./Packages/CloudReaderKotlin/gradlew -p Apps/Desktop run
bash scripts/build-app.sh windows   # on Windows, Git Bash
bash scripts/build-app.sh linux     # on Debian 12
```

`release.properties` owns the Android/Windows/Linux version. The **Android,
Windows and Linux** GitHub workflow builds all three from the same revision and
collects APK/MSI/DEB plus hashes only when every build succeeds. Packages are
previews: Android is debug-signed and Windows MSI is unsigned. Shipping updates
requires stable distribution signing credentials.

Linux requires a graphical session, GTK 3, Fontconfig, X11 compatibility libraries
and a working OpenGL/software graphics stack. JavaFX WebKit and PDFBox are bundled
with the runtime. Linux credentials use `secret-tool` and an unlocked Secret
Service; Windows uses Credential Manager. If storage is unavailable, credentials
are session-only unless the user explicitly enables the disclosed plaintext
fallback and restarts. The fallback is off by default.

## Connections

Folder, Google Drive, Dropbox, pCloud, HTTPS WebDAV and pinned-host-key SFTP use
the same v1 object names and provider namespaces as Apple/Android. A selected
folder contains a `CloudReader/` subdirectory. Google uses `appDataFolder`, not
My Drive. Browser authorization is user-initiated and receives callbacks only on
127.0.0.1. Register Desktop credentials for Google, and a permitted loopback
redirect for Dropbox/pCloud. Actual provider consent/refresh requires a configured
application/account and remains a separate live check.

The assistant supports Responses, Chat Completions and Anthropic Messages with
custom HTTPS endpoints. New reader-created conversations start with book context
off. The preview shows what will be included; sending with consent saves context
in the chat and includes it in selected-destination sync.

## Validation boundaries

Local JVM tests and Mac-hosted shared-app UI review do not establish Windows or
Linux GUI/accessibility/install-update behavior. Those require target-OS checks.
PDF supports dragging over text to select a passage. Comics use bounded image
decoding, adaptive spreads, scrollbars and Ctrl+wheel zoom. Broader publisher-layout
fidelity, physical gestures and screen-reader behavior need target-device acceptance. v1 uses unconditional manifests: synchronize devices
sequentially to reduce concurrent-writer overwrite risk. Live providers and real
Apple↔Android↔desktop round trips require dedicated test accounts/libraries.
