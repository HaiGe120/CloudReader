#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
core_wrapper="$repo_root/Packages/CloudReaderKotlin/gradlew"

if ! command -v java >/dev/null 2>&1 || ! java -version >/dev/null 2>&1; then
  echo "Java 17 or newer is required to run desktop checks." >&2
  exit 2
fi

"$core_wrapper" -p "$repo_root/Packages/CloudReaderKotlin" test
"$core_wrapper" -p "$repo_root/Apps/Desktop" test

if [[ "${CLOUDREADER_PACKAGE:-0}" == "1" ]]; then
  "$core_wrapper" -p "$repo_root/Apps/Desktop" packageDistributionForCurrentOS
fi
