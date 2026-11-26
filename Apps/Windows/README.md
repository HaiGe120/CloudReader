# Windows

Download the **Windows x64 MSI** from the [1.2.3 desktop preview](https://github.com/HaiGe120/CloudReader/releases/tag/v1.2.3-desktop-preview). The release includes SHA-256 checksums, dependency notices and links to the bundled runtimes’ source.

Windows 10/11 x64 uses the shared app in `Apps/Desktop`. JDK 17 builds it; the MSI
includes the runtime. Run `bash scripts/build-app.sh windows` in Git Bash, or use
the **Android, Windows and Linux** workflow to obtain the same-version APK/MSI/DEB
collection. See the desktop README for features, credentials and validation limits.

The MSI uses a stable upgrade UUID. Packages are unsigned previews. Verify actual
installation, update with library retention, file opening, scaling, keyboard and
screen-reader behavior on Windows before production delivery.
