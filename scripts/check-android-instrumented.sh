#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
android_dir="$repo_root/Apps/Android"
device_serial="${ANDROID_SERIAL:-}"

if [[ -z "$device_serial" ]]; then
  echo "Set ANDROID_SERIAL to the serial of the one test device or emulator." >&2
  echo "List available serials with: adb devices" >&2
  exit 2
fi

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

if [[ -n "${ANDROID_HOME:-}" ]]; then
  adb_bin="$ANDROID_HOME/platform-tools/adb"
elif [[ -n "${ANDROID_SDK_ROOT:-}" ]]; then
  adb_bin="$ANDROID_SDK_ROOT/platform-tools/adb"
else
  adb_bin="$(command -v adb || true)"
fi

if [[ -z "$adb_bin" || ! -x "$adb_bin" ]]; then
  echo "Android instrumentation needs adb from Android SDK Platform Tools on PATH." >&2
  exit 2
fi

if ! device_state="$("$adb_bin" -s "$device_serial" get-state 2>/dev/null)" || [[ "$device_state" != "device" ]]; then
  echo "Selected Android device '$device_serial' is not online and authorized." >&2
  exit 2
fi

online_devices="$("$adb_bin" devices | awk 'NR > 1 && $2 == "device" { print $1 }')"
if [[ "$online_devices" != "$device_serial" ]]; then
  echo "Connect only '$device_serial' before running connected instrumentation tests." >&2
  echo "Online ADB devices: ${online_devices:-none}" >&2
  exit 2
fi

cd "$android_dir"
exec ./gradlew --console=plain connectedDebugAndroidTest
