# Windows desktop client

Windows uses the shared Compose Desktop prototype in [`Apps/Desktop`](../Desktop/README.md) while D01/D03 are evaluated. This folder is reserved for Windows-specific adapters and packaging:

- native file picker/drop integration
- Windows Credential Manager adapter for `CredentialStore` (secure default; plaintext only through explicit user opt-in when required)
- file associations, installer, update, and accessibility verification

No Windows installer or OS validation is claimed yet. Run the shared JVM tests first, then verify packaging on an actual Windows runner as required by D05.
