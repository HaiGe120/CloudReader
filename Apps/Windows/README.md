# Windows

Download the x64 MSI from the
[1.2.1 Google connection preview](https://github.com/HaiGe120/CloudReader/releases/tag/v1.2.1-google-connect-preview).
See [release notes](../../docs/releases/1.2.1-google-connect-preview.md) for checksums,
the bundled runtime/source companion and remaining acceptance limits.
Google defaults are bundled; readers do not need IDs/secrets. Live account
consent/refresh/backup remains unverified.

Windows 10/11 x64 uses the shared app in `Apps/Desktop`. JDK 17 builds it; the MSI
includes the runtime. Run `bash scripts/build-app.sh windows` in Git Bash, or use
the **Android, Windows and Linux** workflow to obtain the same-version APK/MSI/DEB
collection. See the desktop README for features, credentials and validation limits.

The MSI uses a stable upgrade UUID. Packages are unsigned previews. Verify actual
installation, update with library retention, file opening, scaling, keyboard and
screen-reader behavior on Windows before production delivery.
