#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/speedsentry-insights.XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT
mkdir -p "$ROOT/.build/insights-module-cache"
export CLANG_MODULE_CACHE_PATH="$ROOT/.build/insights-clang-cache"
xcrun swiftc -parse-as-library -swift-version 5 \
  -module-cache-path "$ROOT/.build/insights-module-cache" \
  "$ROOT"/Sources/SpeedSentryCore/*.swift \
  "$ROOT/Tests/SpeedSentryCoreTests/InsightsScenarios.swift" \
  "$ROOT/scripts/InsightsCheck.swift" -o "$SCRATCH/insights-check"
"$SCRATCH/insights-check"
