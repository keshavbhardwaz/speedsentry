#!/bin/bash
set -euo pipefail

usage() {
  echo 'Usage: bash scripts/package-release.sh APP_PATH ZIP_PATH --keychain-profile PROFILE [--keychain KEYCHAIN_PATH]'
  echo 'Requires a Developer ID signed app. Submits to Apple, staples, verifies, and creates the final ZIP.'
}
if (($# < 2)); then usage >&2; exit 2; fi
APP="$1"
ZIP="$2"
shift 2
PROFILE=""
KEYCHAIN=""
while (($#)); do
  case "$1" in
    --keychain-profile|--keychain)
      (($# >= 2)) || { usage >&2; exit 2; }
      case "$1" in
        --keychain-profile) PROFILE="$2" ;;
        --keychain) KEYCHAIN="$2" ;;
      esac
      shift 2
      ;;
    *) usage >&2; exit 2 ;;
  esac
done
[[ -d "$APP/Contents" && "$ZIP" == *.zip && -n "$PROFILE" ]] || { usage >&2; exit 2; }
case "$APP" in /*) ;; *) APP="$PWD/$APP" ;; esac
case "$ZIP" in /*) ;; *) ZIP="$PWD/$ZIP" ;; esac
codesign --verify --strict --verbose=2 "$APP"
SIGNATURE="$(codesign --display --verbose=4 "$APP" 2>&1)"
[[ "$SIGNATURE" == *'Authority=Developer ID Application:'* ]] || {
  echo 'Public releases require a Developer ID Application signature.' >&2; exit 1;
}
mkdir -p "$(dirname "$ZIP")"
WORK="$(mktemp -d "$(dirname "$ZIP")/.notarize.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
ditto -c -k --sequesterRsrc --keepParent "$APP" "$WORK/submit.zip"
NOTARY_ARGS=(--keychain-profile "$PROFILE")
if [[ -n "$KEYCHAIN" ]]; then NOTARY_ARGS+=(--keychain "$KEYCHAIN"); fi
xcrun notarytool submit "$WORK/submit.zip" "${NOTARY_ARGS[@]}" --wait --timeout 30m
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
codesign --verify --strict --verbose=2 "$APP"
spctl --assess --type execute --verbose=2 "$APP"
# Stapling changes the bundle: the published ZIP and its checksum must be made afterwards.
ditto -c -k --sequesterRsrc --keepParent "$APP" "$WORK/release.zip"
mv "$WORK/release.zip" "$ZIP"
printf 'Notarized release: %s\n' "$ZIP"
