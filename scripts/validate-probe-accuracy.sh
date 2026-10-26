#!/bin/bash
set -euo pipefail

# Runs real paced local TCP downloads without internet access or external tools.
# Three basic cases use 8 MiB each; adaptive uses 8 + 64 MiB: 96 MiB loopback total.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/speedsentry-accuracy.XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT
mkdir -p "$ROOT/.build/accuracy-check-module-cache"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$ROOT/.build/accuracy-check-clang-cache}"
xcrun swiftc -parse-as-library -swift-version 5 \
  -module-cache-path "$ROOT/.build/accuracy-check-module-cache" \
  "$ROOT"/Sources/SpeedSentryCore/*.swift \
  "$ROOT/Tests/SpeedSentryCoreTests/PacedLoopbackServer.swift" \
  "$ROOT/scripts/ProbeAccuracyCheck.swift" -o "$SCRATCH/probe-accuracy"
"$SCRATCH/probe-accuracy"
