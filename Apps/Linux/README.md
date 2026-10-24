# Linux desktop client

Linux uses the shared Compose Desktop prototype in [`Apps/Desktop`](../Desktop/README.md) while D01/D03 are evaluated. This folder is reserved for Linux-specific adapters and packaging:

- native file picker/drop integration
- Secret Service/libsecret adapter for `CredentialStore`
- desktop entry, MIME types, package/runtime dependencies, and accessibility verification

If a Secret Service is unavailable, credentials remain explicitly unavailable by default. Settings may offer the documented plaintext fallback only after explicit opt-in and disclosure; it is protected with user-only file permissions and never synced. No Linux package or distribution support matrix is claimed yet. Verify packaging on the declared Linux runner as required by D06.
