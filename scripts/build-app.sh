#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION=release
UNIVERSAL=0
IDENTITY="-"
OUTPUT="$ROOT/dist/SpeedSentry.app"
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
DISABLE_SWIFT_SANDBOX=0

usage() {
  cat <<'USAGE'
Usage: bash scripts/build-app.sh [--configuration debug|release] [--universal]
                            [--identity 'Developer ID Application: …'] [--output PATH]
                            [--disable-swift-sandbox]
Environment: VERSION (default 0.1.0), BUILD_NUMBER (default 1).
The default ad hoc signature is for development on your own Mac.
USAGE
}

while (($#)); do
  case "$1" in
    --configuration|--identity|--output)
      (($# >= 2)) || { usage >&2; exit 2; }
      case "$1" in
        --configuration) CONFIGURATION="$2" ;;
        --identity) IDENTITY="$2" ;;
        --output) OUTPUT="$2" ;;
      esac
      shift 2
      ;;
    --universal) UNIVERSAL=1; shift ;;
    --disable-swift-sandbox) DISABLE_SWIFT_SANDBOX=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ "$(uname -s)" == Darwin ]] || { echo 'macOS is required.' >&2; exit 1; }
[[ "$CONFIGURATION" == debug || "$CONFIGURATION" == release ]] || { echo 'Invalid configuration.' >&2; exit 2; }
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'VERSION must be X.Y.Z.' >&2; exit 2; }
[[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]] || { echo 'BUILD_NUMBER must be an integer.' >&2; exit 2; }
[[ "$OUTPUT" == *.app ]] || { echo 'Output path must end in .app.' >&2; exit 2; }
[[ -n "$IDENTITY" ]] || { echo 'Signing identity cannot be empty.' >&2; exit 2; }

case "$OUTPUT" in /*) ;; *) OUTPUT="$PWD/$OUTPUT" ;; esac
mkdir -p "$ROOT/dist" "$(dirname "$OUTPUT")"
STAGING="$(mktemp -d "$ROOT/dist/.bundle.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
APP="$STAGING/SpeedSentry.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

build_arch() {
  local arch="$1"
  local scratch="$ROOT/.build/$arch-$CONFIGURATION"
  local swift_args=(--build-system native --package-path "$ROOT" --scratch-path "$scratch" --configuration "$CONFIGURATION" --arch "$arch"
    --cache-path "$ROOT/.build/swiftpm-cache" --config-path "$ROOT/.build/swiftpm-config" --security-path "$ROOT/.build/swiftpm-security")
  if ((DISABLE_SWIFT_SANDBOX)); then swift_args+=(--disable-sandbox); fi
  swift build "${swift_args[@]}" --product SpeedSentry >&2 || return $?
  swift build "${swift_args[@]}" --show-bin-path
}

export MACOSX_DEPLOYMENT_TARGET=13.0
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$ROOT/.build/clang-module-cache}"
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-$ROOT/.build/swift-module-cache}"
if ((UNIVERSAL)); then
  ARM_BIN="$(build_arch arm64)"
  INTEL_BIN="$(build_arch x86_64)"
  xcrun lipo -create "$ARM_BIN/SpeedSentry" "$INTEL_BIN/SpeedSentry" \
    -output "$APP/Contents/MacOS/SpeedSentry"
else
  BIN="$(build_arch "$(uname -m)")"
  cp "$BIN/SpeedSentry" "$APP/Contents/MacOS/SpeedSentry"
fi
chmod 755 "$APP/Contents/MacOS/SpeedSentry"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
if [[ -f "$ROOT/Resources/SpeedSentry.icns" ]]; then
  cp "$ROOT/Resources/SpeedSentry.icns" "$APP/Contents/Resources/SpeedSentry.icns"
fi
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
if [[ "$IDENTITY" == '-' ]]; then
  codesign --force --sign - --options runtime --timestamp=none "$APP"
else
  codesign --force --sign "$IDENTITY" --options runtime --timestamp "$APP"
fi
codesign --verify --strict --verbose=2 "$APP"
if [[ -e "$OUTPUT" ]]; then
  [[ -d "$OUTPUT/Contents" && -f "$OUTPUT/Contents/Info.plist" ]] || {
    echo 'Refusing to replace an output that is not an app bundle.' >&2; exit 1;
  }
  rm -rf "$OUTPUT"
fi
mv "$APP" "$OUTPUT"
printf 'Built %s (%s)\n' "$OUTPUT" "$(xcrun lipo -archs "$OUTPUT/Contents/MacOS/SpeedSentry")"
