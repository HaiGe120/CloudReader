#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
android_dir="$repo_root/Apps/Android"

if [[ -n "${JAVA_HOME:-}" ]]; then
  java_bin="$JAVA_HOME/bin/java"
  javac_bin="$JAVA_HOME/bin/javac"
else
  java_bin="$(command -v java || true)"
  javac_bin="$(command -v javac || true)"
fi

if [[ -z "$java_bin" || ! -x "$java_bin" || -z "$javac_bin" || ! -x "$javac_bin" ]] || ! "$java_bin" -version >/dev/null 2>&1 || ! "$javac_bin" -version >/dev/null 2>&1; then
  echo "Android checks need a working JDK 17 or newer; set JAVA_HOME to that JDK." >&2
  exit 2
fi
java_major="$("$java_bin" -version 2>&1 | awk -F'[".]' 'NR == 1 { if ($2 == 1) print $3; else print $2 }')"
if [[ ! "$java_major" =~ ^[0-9]+$ ]] || (( java_major < 17 )); then
  echo "Android checks need JDK 17 or newer; found Java ${java_major:-unknown}." >&2
  exit 2
fi

if [[ -z "${ANDROID_HOME:-}${ANDROID_SDK_ROOT:-}" && ! -f "$android_dir/local.properties" ]]; then
  echo "Android checks need an SDK path; set ANDROID_HOME/ANDROID_SDK_ROOT or create Apps/Android/local.properties." >&2
  exit 2
fi

cd "$android_dir"
exec ./gradlew --console=plain testDebugUnitTest lintDebug assembleDebug
