# RELEASE-1.2.1 — coordinated publication evidence

Date: 2026-11-01. Scope: authorized GitHub APK/MSI/DEB preview publication;
no native Apple/App Store changes. Source: `48d8b5e154bc5b101bb85051d869836e02039069`.
Tag: `v1.2.1-google-connect-preview` (must target the compiled source, not newer docs).
[Coordinated run 41315984334](https://github.com/HaiGe120/CloudReader/actions/runs/41315984334): all five jobs successful.

## Verified build/package boundary

- Windows MSI and Debian DEB are unchanged outputs from that exact run.
- Android was freshly built from the same frozen revision/version on the
  maintainer's Mac with pinned Temurin 17.0.20+8, retained debug key and isolated
  build directory. No CI APK re-signing and no private signing key upload.
- Android package `io.github.haige120.cloudreader`, 1.2.1/code 5, min API 31,
  target 37, v2 signature verified. SHA-1
  `E3:F7:0B:33:F7:71:2E:FC:B3:75:5B:82:59:5F:BF:43:19:1E:11:9B`.
- Public 1.2.0 used temporary 4F:2D signing and cannot be updated by this key.
  **Do not uninstall/clear data.** Older-key installed update/data retention is
  untested; certificate continuity alone is not migration acceptance.
- MSI SummaryInformation confirms x64. DEB control confirms amd64/1.2.1-1.
  Bundled Java is pinned 17.0.20+8; DEB release file confirms 17.0.20 and its
  actual libjvm binary contains build string 17.0.20+8. OpenJFX is 21.0.9.
- Final manifests were re-collected from local Android plus CI desktop; all
  three share one version/revision. Individual APK and bundled APK are identical.

## Fresh checks on final source

| Check | Tests | Failures / errors / skipped |
| --- | ---: | --- |
| CI Android JVM | 127 | 0 / 0 / 0 |
| Local release Android JVM | 127 | 0 / 0 / 0 |
| Windows target-OS suite | 53 | 0 / 0 / 0 |
| Debian target-OS suite | 53 | 0 / 0 / 0 |
| Shared core local rerun (CI core gate also passed) | 20 | 0 / 0 / 0 |
| Collector | 4 | 0 / 0 / 0 |
| Actual local release APK settings UI | 6 | 0 / 0 / 0 |

Android lint/assembly passed. Six UI tests ran only on a new disposable Android
12/API 31 ARM64 emulator, with real production settings UI and memory-backed
settings services. Four card tests cover 320/360dp at 1.5× font in both themes;
two test standard/Advanced controls in real settings. Runner returned `OK (6 tests)`.
All six Android/desktop real light/dark settings screenshots were visually reviewed.
The owned test emulator was shut down; personal devices/libraries were not used.

Each actual Windows/Debian bundled launcher passed PDF rendering, WebKit load,
page turn, actual shared library, light settings, dark settings and isolated
library checks. Each target-OS suite includes four native-reader GUI tests.
Contrast tests cover 17 text pairs at a minimum 4.5:1 ratio.

## Google configuration proof, not live OAuth acceptance

Approved repository variable/secret names were configured and metadata verified.
Raw downloaded JSON remains ignored and private. No Android signing private key
or personal Google access/refresh token was uploaded. Desktop is an installed
public client; its configuration is deliberately bundled inside app resources,
not a confidential Web-server credential.

Both bundled launchers returned `googleDefaultsConfigured: true` and matched the
approved input SHA-256 fingerprint:
`8c8b1f0e8893fbbdf16b1f907c1e1a4359917e9498d3bbf477cb23520aaebb1e`.
No raw secret values occur in evidence. The retained Android certificate's
registration is already present. Drive API/registrations were checked earlier;
existing Rclone registrations, consent branding/audience and billing were retained.

**No successful personal-account consent, token renewal or Drive backup/sync
is claimed on Android, Windows or Linux.** User has not retried the connection.

## Inventory and corresponding-source verification

- Each tested desktop app image reports 65 actual app-directory JARs and hashes.
- All DEB application-code/dependency hashes match the tested image except its
  generated Skiko native-runtime placeholder. This 293-byte JAR contains only
  an empty directory and `Manifest-Version: 1.0`, no code or native library.
  Replacing only its four ZIP timestamp fields reconstructs the tested-image
  SHA-256 exactly. Both precise inventories/hashes are retained; they are not
  mislabeled as byte-identical. The runtime's `jrt-fs.jar` is outside the app inventory.
- Current Windows inventory describes the tested app image; it is not an MSI
  extraction/install claim. MSI/DEB installed/update acceptance remains open.
- Dependency declarations/lockfiles match 1.2.0. Verbatim legal texts are retained
  from its checksum-verified notices archive. Android retained notices were
  compared byte-for-byte with the actual new APK. Historical app-JAR metadata
  lives under an explicitly named baseline; new inventories identify current JARs.
- Matching Temurin 17.0.20+8 and OpenJFX 21.0.9+1 sources were verified against
  the prior checked asset manifest; Java source also matches upstream checksum.
  Notices are distribution information, not an exhaustive legal audit/SBOM.

## Checksums and publication

| Package | SHA-256 |
| --- | --- |
| `CloudReader-1.2.1-android-debug.apk` | `28473d9f8a4647ecc4fe80fc917b27ae73a2b96db358a84e3757211227b5f707` |
| `CloudReader-1.2.1-linux.deb` | `571d9e8c4888bdaa76c5f52366b6d41d34bfed9199a6b4dab321c4627ba45cb8` |
| `CloudReader-1.2.1-windows.msi` | `af652d15df5a09bd20e24ab461a28dab8d56273da043edce36788afa895a59fa` |

The release includes package manifests, release-wide SHA256SUMS, provenance,
retained XML/runtime/UI proof, project/dependency notices and matching sources.
The release tag targets the compiled SHA. Documentation is committed separately;
`build-provenance.json` records its publication-document revision.

Draft asset digests, tag target, public downloads, prerelease flags and public
default-branch documentation are verified in the final publication receipt below.

### Publication receipt

Published [CloudReader 1.2.1 preview](https://github.com/HaiGe120/CloudReader/releases/tag/v1.2.1-google-connect-preview) at
**2026-11-01T14:53:54Z**. Release ID `430649133`; public, prerelease,
not draft; published with `latest=false`.

- All **18 draft asset sizes and GitHub SHA-256 digests** matched the local
  validated manifest before publication. No public asset was overwritten.
- After publication, **all 18 public assets were downloaded without authentication**
  and independently SHA-256/size-verified at `2026-11-01T14:55:59.671964+00:00`.
- Public tag resolves to compiled revision `48d8b5e154bc5b101bb85051d869836e02039069`.
- Public `main` was safely fast-forwarded (no force) to publication documentation
  `f7df10e71d4e78c93e4d1c750b56476374dabfd5`; this receipt is a later
  documentation-only commit. Public README and original MIT license were fetched
  without authentication and compared byte-for-byte; private security reporting
  remains enabled.
- All-platform ZIP SHA-256:
  `6483b83a1477f87e00cc1fde1d2b867ae1286df0b53ec952ea35d4db00ee7fe1`.
  Its APK digest matches the individually published locally signed APK.
- Raw credentials, signing private keys, personal books and account tokens were
  excluded. Eight unrelated tracked diffs remain byte-for-byte preserved.

Download assets retain the frozen pre-publication evidence/provenance; this live
receipt does not rewrite those verified bytes or imply new live OAuth acceptance.

## Remaining acceptance limits

Live Google/other providers/AI and cross-platform sync, physical Android,
installed updates/library retention, MSI/DEB installation, OS vaults and broad
accessibility/display matrices remain unverified. Windows unsigned. Full iOS
parity and desktop export/share remain open; schema-v1 concurrent writers can
overwrite unseen manifests. No schema/credential identifier/dependency/minimum
SDK/native Apple changes were made. Eight unrelated tracked changes and unrelated
untracked work were preserved, not committed as part of this release.

## Actual settings screenshots

| Android | Windows | Debian |
| --- | --- | --- |
| [Light](../../images/1.2.1/android-settings-light.png) / [Dark](../../images/1.2.1/android-settings-dark.png) | [Light](../../images/1.2.1/windows-settings-light.png) / [Dark](../../images/1.2.1/windows-settings-dark.png) | [Light](../../images/1.2.1/linux-settings-light.png) / [Dark](../../images/1.2.1/linux-settings-dark.png) |
