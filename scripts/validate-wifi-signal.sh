#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/speedsentry-wifi.XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT
mkdir -p "$ROOT/.build/wifi-module-cache"
export CLANG_MODULE_CACHE_PATH="$ROOT/.build/wifi-clang-cache"
xcrun swiftc -parse-as-library -swift-version 5 \
  -module-cache-path "$ROOT/.build/wifi-module-cache" \
  "$ROOT"/Sources/SpeedSentryCore/*.swift \
  "$ROOT/Tests/SpeedSentryCoreTests/WiFiSignalScenarios.swift" \
  "$ROOT/scripts/WiFiSignalCheck.swift" -o "$SCRATCH/wifi-check"
"$SCRATCH/wifi-check"
