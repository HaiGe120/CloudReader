#!/usr/bin/env bash
set -euo pipefail

reader_repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
reader_checks_dir="${CLOUDREADER_MAC_CHECKS_DIR:-/tmp/CloudReader-MacReaderChecks}"
reader_mode="${1:-unit}"
reader_selection=()
case "$reader_mode" in
  unit) reader_selection=(-only-testing:CloudReaderMacTests) ;;
  ui) reader_selection=(-only-testing:CloudReaderMacUITests) ;;
  all) ;;
  *) echo "Usage: $0 [unit|ui|all]" >&2; exit 2 ;;
esac

cd "$reader_repo_root"
xcodegen generate --spec Apps/macOS/CloudReader.xcodegen.yml
# Separate app identity, isolated launch libraries/preferences, no personal sync.
# Only this test build omits sandboxing so fixtures can be read from the checkout.
exec xcodebuild -project Apps/macOS/CloudReader.xcodeproj -scheme CloudReader \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$reader_checks_dir" \
  CLOUDREADER_APP_BUNDLE_IDENTIFIER=io.github.haige120.cloudreader.macos.readerChecks \
  ENABLE_APP_SANDBOX=NO CODE_SIGN_ENTITLEMENTS='' \
  CODE_SIGNING_ALLOWED=YES CODE_SIGNING_IDENTITY=- \
  "${reader_selection[@]}" test
