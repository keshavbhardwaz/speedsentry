#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/speedsentry-context.XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT
mkdir -p "$ROOT/.build/context-module-cache"
export CLANG_MODULE_CACHE_PATH="$ROOT/.build/context-clang-cache"
xcrun swiftc -parse-as-library -swift-version 5 \
  -module-cache-path "$ROOT/.build/context-module-cache" \
  "$ROOT"/Sources/SpeedSentryCore/*.swift \
  "$ROOT/Tests/SpeedSentryCoreTests/NetworkContextScenarios.swift" \
  "$ROOT/scripts/NetworkContextCheck.swift" -o "$SCRATCH/context-check"
"$SCRATCH/context-check"
