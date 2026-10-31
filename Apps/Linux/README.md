# Linux

Download the amd64 DEB from the
[1.2.0 unified prerelease](https://github.com/HaiGe120/CloudReader/releases/tag/v1.2.0-unified-preview).
See [release notes](../../docs/releases/1.2.0-unified-preview.md) for checksums,
native dependencies, runtime/source companions and verification limits.

Debian 12 x64 is the packaging baseline for the shared app in `Apps/Desktop`.
Run `bash scripts/build-app.sh linux` with JDK 17 and the `fakeroot`/Debian packaging
tools, or use the **Android, Windows and Linux** workflow for a same-version
APK/MSI/DEB collection. Other distributions may build from source.

A graphical session, GTK 3, Fontconfig, X11 compatibility and graphics libraries
are required. `secret-tool` plus an unlocked Secret Service persist credentials;
unavailable storage is session-only unless the disclosed fallback is explicitly
enabled. See the desktop README for the current feature and verification limits.
