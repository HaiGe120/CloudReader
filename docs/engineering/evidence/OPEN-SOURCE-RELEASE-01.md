# Open-source preview publication — 2026-10-31

Status: coordinated release build, local checks and all **18 uploaded draft
asset sizes/SHA-256 digests verified**; public publication pending.

## Authorized scope and preservation

The user explicitly authorized publishing the three-platform preview to GitHub
Releases and updating the README and related open-source material. The repository
was already public, MIT licensed, with `main` as its unprotected default branch.
The existing license grant is retained; no dependency is relicensed.

Owned paths: root README, `.gitignore`, CONTRIBUTING/SECURITY/CHANGELOG; GitHub
issue/PR templates and coordinated workflow runtime pins; Android/Desktop/
Windows/Linux READMEs and iOS guide; product-status correction; third-party notice/license
copies; release guide, notes, screenshots and related task evidence. Generated
publication assets are isolated under `Build/ReleasePublication/1.2.0/` and ignored.

Pre-existing Apple changes, the implementation plan, untracked duplicate files,
App Store drafts and unrelated evidence are not staged. The task's starting
status and unrelated tracked diff are saved under the publication directory.
No app library, credentials, update identity or provider destination is changed.

## Reproducible release input

Initial tested checkpoint: `06132a50c268f9b6a7a8681d0e8d07e5eacbe16e`, run
`41186055676`. During publication checks, its Windows Java cache resolved to
17.0.20+101 while Debian downloaded 17.0.21+9. A first exact 17.0.21+9 pin correctly
failed the Windows gate: that release had no official Windows asset. It is not
published and no gate was bypassed.

The corrected release revision is
`6973577172f0da70f752b8f51e76b5dc470975b0`, pinning **Temurin 17.0.20+8**,
verified to have official Windows/Linux binaries and matching source. Application
code, dependency versions, schema v1 and Android identity/minimums are unchanged.
The prerelease tag `v1.2.0-unified-preview` will point at that compiled revision;
later documentation commits are separate.

## Open-source/distribution preparation

- Public MIT source retained; contribution/security guides, issue/PR templates,
  changelog, source-build/release instructions and actual UI screenshots added.
- Private vulnerability reporting enabled and confirmed via the repository API.
- Historical Android certificate assumptions and untracked-evidence links removed
  from the public guide. CI debug signatures are explicitly not safe update keys.
- Credential-pattern and sensitive-file-name checks on intended tracked source
  found no matching secrets/signing files; this is not a comprehensive security audit.
- Full retained dependency/runtime license notices, runtime Maven metadata and
  verbatim upstream attributions prepared as a companion. OpenJFX's previously
  invalid source link corrected to the actual `openjdk/jfx21u` tag `21.0.9+1`.
- Matching Temurin and OpenJFX source archives retained for publication. The JDK
  source archive is checked against its upstream SHA-256. Native runtime legal
  notices remain alongside the bundled Java runtime.
- The notice companion contains **575** retained files, **220** Android debug
  runtime Maven coordinate records and an inventory of **65** actual packaged
  desktop JARs (60 mapped to cached Maven coordinates). It is distribution
  provenance, not a claim of a comprehensive security/legal audit or full SBOM.

Final build, uploaded asset checksums, public URLs and default-branch verification
will be recorded below after the draft is verified and published.

## Final release build and local checks

Run `41190223599` completed **successfully** at 2026-10-31 09:57:51 UTC.
Core, Android, Windows, Debian and collection all passed for compiled revision
`6973577172f0da70f752b8f51e76b5dc470975b0`. Both desktop setup logs independently
confirmed Temurin **17.0.20+8**, rather than a loose major-version cache selection.
No application source differs from the initially validated checkpoint.

- Android: **121** JVM tests, no failures/errors/skips; lint/APK assembly passed.
- Windows and Debian: **15** tests each, no failures/errors/skips, including four
  native-reader tests per OS. Both bundled runtimes returned true for PDF render,
  WebKit load/page turn, actual shared-library UI and isolated-library checks.
- Both final target-OS library screenshots were inspected. README screenshots
  are actual running-app captures, not mockups. The Android screenshot and **29**
  emulator tests come from the isolated local build of unchanged application code.
- Shared-core **20** local tests and **4** collector tests passed. No physical
  device, installed-OS update, real cloud account or live AI acceptance is claimed.
- The final combined artifact was downloaded; all three package digests matched
  its manifests. APK v2 signing, app ID, version code 4, minimum API 31 and target
  API 37 were checked independently. Its debug certificate SHA-1 is
  `4F:2D:16:4E:E4:43:9D:5E:6A:1F:76:F2:AF:38:EC:6A:A9:77:84:C7`.
- Documentation relative links and issue/workflow YAML passed local checks.
  Secret/signing-file patterns found no matches; pre-existing eight tracked-file
  diffs compared byte-for-byte unchanged to the starting snapshot.
- Authored-file whitespace checks passed. Thirteen upstream license/notice files
  were byte-compared with their retained originals; their inherited whitespace is
  preserved rather than reformatted, and excluded from authored-file style checks.

| Public application asset | SHA-256 |
| --- | --- |
| `CloudReader-1.2.0-android-debug.apk` | `d40ce4bd45422997290af3a44e83494dae9abe3ac2b7e7bcf9a00357773b20f1` |
| `CloudReader-1.2.0-windows.msi` | `4261ea8823e89192de3717d8ace00a2ceb2f2bee86cab5105d33864d23895fb2` |
| `CloudReader-1.2.0-linux.deb` | `621ecd822e80dcff8799ffb9fa60b85600091740755bc541c21cccc65e13c951` |

The 57-entry all-app bundle passed ZIP integrity checks, includes exactly one
APK/MSI/DEB and retains the license companion and labeled runtime/UI/test evidence.
Its SHA-256 is
`453b480bce7c2915f3b7899b45359709f2e7e8649061110c361385d6e345fee5`.
Release-wide `SHA256SUMS` covers the other 17 assets; no package was re-signed or
changed after CI download. The old local delivery remains intact and is not
mistaken for this new public build.

Draft release ID: `429850183`. Every one of the 18 uploaded asset names, sizes,
`uploaded` states and GitHub-reported `sha256:` digests matched the local asset
manifest before publication. The draft target is the exact compiled revision;
no public asset was overwritten or published before these checks.
