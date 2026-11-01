# Coordinated preview release procedure

Keep source/build provenance, signing status and live acceptance separate. A
successful workflow does not authorize a public release; obtain user/maintainer
authorization first. Do not change App Store release/submission state here.

## 1. Freeze and verify inputs

1. Preserve the dirty worktree. Stage only owned files, never all untracked files.
2. Check repository visibility, license, existing tag/release and default branch.
   Retain the existing MIT grant and all third-party terms; do not relicense dependencies.
3. Confirm `release.properties`, Android identity/version code and intended update
   signing identity. Debug CI keys are not stable update keys.
4. Pin the coordinated JDK patch/build. `java-version: 17` can select different
   cached runtimes on different runners. Record matching runtime source versions.
5. Scan the intended tracked source and release documents for credentials and
   private data. Do not publish local App Store drafts, user books or personal sync data.

## 2. Build and collect

Push the intended revision and run **Android, Windows and Linux**. Require core,
Android, Windows, Debian and final collection success. Review test XMLs, actual
UI screenshots and bundled-runtime proof, including failures/skips. Preserve
the evidence independently of GitHub artifact expiration.

Download only the combined artifact for that exact revision:

```sh
gh run download RUN_ID \
  -n CloudReader-all-platforms-COMPILED_SHA \
  -D Build/ReleasePublication/VERSION/input
python3 scripts/collect-apps.py collect Build/ReleasePublication/VERSION/input \
  --version VERSION --revision COMPILED_SHA
```

Validate APK identity/signature, MSI architecture, DEB control metadata and each
hash. Do not re-sign or silently replace a validated package. If runtime/build
inputs change, regenerate the coordinated set and record its new compiled SHA.

### Android signing kept on the maintainer's Mac

The 1.2.0 CI private debug key was not retained. A public certificate from that
APK cannot be used to sign an update. Do not upload the retained local signing
key merely to make CI produce the release APK.

For 1.2.1, require the full coordinated CI gates, then build a **fresh Android
package from the same frozen revision/version** locally with the retained older
preview key and pinned JDK 17.0.20+8. Run unit/lint, actual-APK UI and signature
checks on that local package. Stage it separately from CI's test-only APK; stamp
and re-collect the three release packages with `collect-apps.py` before verifying
the final manifests. Never re-sign an already validated CI APK. Record the local
Android builder, toolchain, certificate and independent checks in provenance.

The retained key matches older E3:F7 previews, **not** the 4F:2D 1.2.0 APK. This
does not provide an in-place 1.2.0 update. Keep that warning in downloads and
release notes; do not suggest uninstalling or clearing the user's library.

Official Windows/Linux builds must supply the maintainer-owned Desktop Google
client through protected build settings. Require the bundled-runtime proof of
configuration presence and compare its fingerprint with the approved input.
Never include a raw downloaded credential JSON or a signing keystore in source
or release assets. A configured client is not evidence of a live OAuth round trip.

## 3. Prepare publication

- Update the root/platform READMEs, changelog, release notes and engineering evidence.
- Supply the project license, complete retained dependency notices/attributions,
  and matching bundled-runtime source archives. Verify upstream source checksums
  when supplied. Keep compiler-only/test-only dependencies distinct from runtime code.
- Package all three apps and evidence together, retaining the individual package
  hashes. Create release-wide `SHA256SUMS` including companions and the final ZIP.
- Audit local Markdown links against files that will actually be tracked on GitHub.
- Update the public default branch only without discarding others' changes. Prefer
  a safe fast-forward when it is an ancestor; otherwise use a reviewed integration PR.

## 4. Stage, verify, then publish

Use a new prerelease tag pointing at the **compiled** SHA. Keep a draft until all
assets are uploaded and verified. Never use `--clobber` on public assets by default.

```sh
gh release create TAG --target COMPILED_SHA --draft --prerelease \
  --title TITLE --notes-file docs/releases/RELEASE_NOTES.md
gh release upload TAG Build/ReleasePublication/VERSION/assets/*
```

Check asset names, sizes and uploaded SHA-256 digests against local files. If
GitHub does not report asset digests, download and rehash them. Confirm that the
tag resolves to the compiled SHA, then publish:

```sh
gh release edit TAG --draft=false --prerelease --latest=false
```

Verify public download access, release status and metadata, default-branch README
and license, private security reporting, and installed-package warnings. Record
the final URL/tag, source/doc SHAs, build run and hashes in release evidence.
Never mark unsigned/debug previews stable or claim untested live-provider parity.
