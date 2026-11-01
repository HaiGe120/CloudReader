# CloudReader for Windows and Linux

The desktop app shares its library/navigation, assistant UI, portable values,
merge rules, AI transport and EPUB/FB2/CBZ preparation with Android. Native hosts
provide file access, credential storage, PDF rendering and WebKit. The current
reader scope follows the enabled iOS readers: TXT, PDF, EPUB, FB2 and CBZ.
MOBI/AZW3/CBR remain importable storage-only formats.

## 1.2.1 Google connection preview

Download the [1.2.1 prerelease](https://github.com/HaiGe120/CloudReader/releases/tag/v1.2.1-google-connect-preview):
Windows x64 MSI, Debian 12 amd64 DEB, or the all-platform preview ZIP.
Compiled revision: `48d8b5e154bc5b101bb85051d869836e02039069`; coordinated run `41315984334`.
See [release notes and exact hashes](../../docs/releases/1.2.1-google-connect-preview.md).
Keep the notices companion and matching Java/OpenJFX sources with redistributions.
Windows remains unsigned; installed/update acceptance is not yet complete.

The existing library at `~/.cloudreader-desktop` is retained, including prototype
properties files and UTF-16 TXT offsets. Original imported files are copied. New
metadata writes are staged, deletion records are durable, and credentials stay
outside portable manifests. `CLOUDREADER_DESKTOP_HOME` selects a separate library
for test and development runs.

## Build

Use JDK 17; coordinated release CI pins Temurin 17.0.20+8. Windows packaging
requires WiX Toolset 3 and Git Bash; Linux packaging requires Debian packaging
tools, a graphical session and native GUI libraries. From the repository root:

```sh
./Packages/CloudReaderKotlin/gradlew -p Apps/Desktop test
./Packages/CloudReaderKotlin/gradlew -p Apps/Desktop run
bash scripts/build-app.sh windows   # on Windows, Git Bash
bash scripts/build-app.sh linux     # on Debian 12
```

`release.properties` owns the Android/Windows/Linux version. The **Android,
Windows and Linux** GitHub workflow builds all three from the same revision and
collects APK/MSI/DEB plus hashes only when every build succeeds. Packages are
previews: Windows MSI is unsigned. The public 1.2.1 Android APK is built locally
from the same frozen source/version with a retained preview key, separately from
the CI debug APK; no signing private key is uploaded. It cannot update public
1.2.0 in place. See the [Android signing boundary](../Android/README.md).

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
127.0.0.1. The 1.2.1 preview uses a dedicated new CloudReader **Desktop app** OAuth
client, so normal users only choose **Connect Google Drive**, choose an account
and approve consent. The approved protected build settings are configured. Both actual bundled
launchers proved the expected default client/fingerprint without exposing values.
Optional custom Google credentials are hidden under Advanced; existing configured
grants are retained until an intentional mode/credential change. The public 1.2.0
preview uses the older manual-credential layout. Shared destination cards now
pair foreground/background colors in light and dark themes across all three apps.
See [Google setup for users and maintainers](../../docs/GOOGLE_DRIVE_SETUP.md)
and [prior repair evidence](../../docs/engineering/evidence/GOOGLE-CONNECT-UI-01.md).
Both approved new Google clients were created and verified; the existing Drive
API is enabled and the audience is **External / In production**. Registration and
consent status do not establish successful account authorization. The owner has
not retried personal-account sign-in; live connection, refresh and Drive sync are
**not verified**. The existing project branding remains unchanged and may still say Rclone.
The earlier repair evidence remains a historical checkpoint; see the final release record.
Dropbox/pCloud registrations need a permitted loopback redirect. Actual consent/refresh requires a configured
application/account and remains a separate live check.

The assistant supports Responses, Chat Completions and Anthropic Messages with
custom HTTPS endpoints. New reader-created conversations start with book context
off. The preview shows what will be included; sending with consent saves context
in the chat and includes it in selected-destination sync.

## Validation boundaries

The final source `48d8b5e154bc5b101bb85051d869836e02039069`, coordinated
run `41315984334`, passed **53 tests per OS with zero failures/errors/skips** on
Windows Server 2022 and Debian 12. Both bundled launchers passed PDF render,
WebKit load/page turn, actual library UI, light/dark settings and isolated-library
checks, plus approved Google-default presence/fingerprint verification. All four
desktop settings screenshots were visually inspected. Shared contrast tests
cover 17 text pairs. Actual app-image/runtime JAR inventories are retained.

The DEB's application/dependency JAR hashes match the tested image, except a
manifest-only Skiko placeholder proven to differ only in ZIP timestamps; it has
no executable code. Exact package and tested-image inventories are labeled in
[release evidence](../../docs/engineering/evidence/RELEASE-1.2.1.md). These checks
do not install the MSI/DEB or establish OS-vault, broad accessibility, graphics,
scaling or install/update behavior. Those remain target-device acceptance work.
PDF supports dragging over text to select a passage. Comics use bounded image
decoding, adaptive spreads, scrollbars and Ctrl+wheel zoom. Broader publisher-layout
fidelity, physical gestures and screen-reader behavior need target-device acceptance. v1 uses unconditional manifests: synchronize devices
sequentially to reduce concurrent-writer overwrite risk. Live providers and real
Apple↔Android↔desktop round trips require dedicated test accounts/libraries.
Native Apple apps, schema v1, dependencies, SDK minimums, app IDs and
credential-storage identifiers are unchanged by this release.
