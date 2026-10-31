# Contributing to CloudReader

Thanks for helping improve CloudReader. Its original source is MIT licensed.
Preserve offline reading, imported originals and existing libraries before
expanding functionality.

## Before you start

- For a substantial feature, open an issue first and identify the platform/scope.
- For vulnerabilities, use [private reporting](SECURITY.md), not a public issue.
- Read [AGENTS.md](AGENTS.md) and the [engineering entry point](docs/engineering/README.md).
  The backlog describes possible work, not an instruction to rewrite everything.
- iOS is the product reference. Android stays Kotlin/Compose; Windows and Linux
  share Compose UI and the portable Kotlin core. Keep readers/credentials at OS boundaries.
- Do not change schema v1, migrations, preference keys, application IDs, signing
  identities, SDK minimums or dependency resolutions as incidental cleanup.

## Set up and build

Fork the repository and create a focused branch. Follow the platform setup:
[Android](Apps/Android/README.md), [Windows/Linux](Apps/Desktop/README.md),
[iOS](docs/IOS_FIRST.md), or the Apple XcodeGen specifications under `Apps/`.
Use JDK 17 for Kotlin builds; build each installer on its own OS.
Provider credentials are optional for offline development. Never commit secrets,
OAuth grants, signing keys, exported libraries or personal book files.

## Checks

Run the relevant checks, then any dependent integration gates:

```sh
./Packages/CloudReaderKotlin/gradlew -p Packages/CloudReaderKotlin test --no-daemon --max-workers=2
./Packages/CloudReaderKotlin/gradlew -p Apps/Desktop test --no-daemon --max-workers=2
bash scripts/check-android.sh
python3 -m unittest discover -s scripts -p 'test_collect_apps.py'
git diff --check
```

Native desktop reader tests need a graphical session. Coordinated Linux CI uses
Xvfb and `CLOUDREADER_GUI_TESTS=1` for GUI checks. A skipped test is not device evidence.

For Android instrumentation, select **one disposable emulator/test device**:

```sh
ANDROID_SERIAL=emulator-5554 bash scripts/check-android-instrumented.sh
```

Check the serial with `adb devices` and replace the example. Never use a device
with an important library. Tests must use temporary files, isolated preferences
and test databases—not a personal library or cloud destination.

Shared Apple changes must check both iOS and macOS. XcodeGen YAML is canonical:
regenerate projects after specification changes. Do not compile historical
duplicate sources alongside active replacements. Wire/merge changes must pass
the shared `Contracts/v1` fixtures in both languages.

## Pull requests

- Explain the problem, owned paths, user-visible effect and remaining limits.
- Add regression tests and use original or properly licensed fixtures.
- For UI changes, include running-app screenshots and the OS, device/emulator
  and screen size. Do not present mockups or builds as UI testing.
- Report exact commands/results, skipped tests and untested live providers.
- Keep unrelated files, generated projects and local data out of the change.
- Retain copyright/license notices. Contributions use the repository's MIT
  license unless an existing third-party file specifies otherwise.

Keep discussion respectful and actionable. Maintainers may request a smaller
change or more checks; there is no promised review schedule.
