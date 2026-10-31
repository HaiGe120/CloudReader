#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
target="${1:-}"
output="${CLOUDREADER_OUTPUT_DIR:-$repo_root/Build/Coordinated/$target}"
version="$(sed -n 's/^version=//p' "$repo_root/release.properties" | tr -d '\r')"
revision="${GITHUB_SHA:-$(git -C "$repo_root" rev-parse HEAD)}"
mkdir -p "$output"
export CLOUDREADER_BUILD_ROOT="${CLOUDREADER_BUILD_ROOT:-$(mktemp -d "${TMPDIR:-/tmp}/cloudreader-build.XXXXXX")}"
# Java does not translate MSYS paths passed through environment variables.
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) export CLOUDREADER_BUILD_ROOT="$(cygpath -m "$CLOUDREADER_BUILD_ROOT")" ;;
esac
common=(--no-daemon --max-workers=2 -Dorg.gradle.parallel=false -Dorg.gradle.jvmargs=-Xmx2g -Pkotlin.compiler.execution.strategy=in-process -I "$repo_root/scripts/isolated-build.init.gradle" --project-cache-dir "$CLOUDREADER_BUILD_ROOT/gradle-state/$target")
case "$target" in
  android)
    "$repo_root/Apps/Android/gradlew" -p "$repo_root/Apps/Android" testDebugUnitTest lintDebug assembleDebug "${common[@]}"
    cp "$CLOUDREADER_BUILD_ROOT/CloudReader_app/outputs/apk/debug/app-debug.apk" "$output/CloudReader-$version-android-debug.apk"
    ;;
  windows|linux)
    case "$(uname -s):$target" in
      MINGW*:windows|MSYS*:windows|CYGWIN*:windows|Linux:linux) ;;
      *) echo "Package $target on its own operating system, or run the coordinated GitHub workflow." >&2; exit 2 ;;
    esac
    "$repo_root/Packages/CloudReaderKotlin/gradlew" -p "$repo_root/Apps/Desktop" test createDistributable packageDistributionForCurrentOS "${common[@]}"
    python3 "$repo_root/scripts/check-packaged-desktop.py" "$CLOUDREADER_BUILD_ROOT/CloudReaderDesktop_/compose/binaries/main/app" "$output/checks"
    extension=deb; [[ "$target" == windows ]] && extension=msi
    package="$(find "$CLOUDREADER_BUILD_ROOT/CloudReaderDesktop_/compose/binaries/main" -type f -name "*$version*.$extension" -print -quit)"
    [[ -n "$package" ]] || { echo "No $extension package was produced" >&2; exit 1; }
    cp "$package" "$output/CloudReader-$version-$target.$extension"
    ;;
  *) echo "Usage: scripts/build-app.sh android|windows|linux" >&2; exit 2 ;;
esac
python3 "$repo_root/scripts/collect-apps.py" stamp "$output" --platform "$target" --version "$version" --revision "${GITHUB_SHA:-$revision}"
