#!/bin/bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: bash scripts/generate-cask.sh --repository OWNER/REPO --version X.Y.Z
       --artifact ZIP_BASENAME --sha256 SHA256 --output PATH
Use the SHA-256 of the exact, stapled release ZIP uploaded to GitHub.
USAGE
}
REPOSITORY=""
VERSION=""
ARTIFACT=""
SHA256=""
OUTPUT=""
while (($#)); do
  (($# >= 2)) || { usage >&2; exit 2; }
  case "$1" in
    --repository) REPOSITORY="$2" ;;
    --version) VERSION="$2" ;;
    --artifact) ARTIFACT="$2" ;;
    --sha256) SHA256="$2" ;;
    --output) OUTPUT="$2" ;;
    *) usage >&2; exit 2 ;;
  esac
  shift 2
done
[[ "$REPOSITORY" =~ ^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { echo 'Invalid GitHub OWNER/REPO.' >&2; exit 2; }
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Version must be X.Y.Z.' >&2; exit 2; }
[[ "$ARTIFACT" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*\.zip$ ]] || { echo 'Artifact must be a ZIP basename.' >&2; exit 2; }
[[ "$SHA256" =~ ^[A-Fa-f0-9]{64}$ ]] || { echo 'SHA-256 must contain 64 hex digits.' >&2; exit 2; }
[[ -n "$OUTPUT" ]] || { usage >&2; exit 2; }
mkdir -p "$(dirname "$OUTPUT")"
cat > "$OUTPUT" <<CASK
cask "speedsentry" do
  version "$VERSION"
  sha256 "$SHA256"

  url "https://github.com/$REPOSITORY/releases/download/v#{version}/$ARTIFACT"
  name "SpeedSentry"
  desc "Menu bar download speed monitor with alerts and IST incident history"
  homepage "https://github.com/$REPOSITORY"

  depends_on macos: ">= :ventura"

  app "SpeedSentry.app"

  uninstall quit: "app.speedsentry.mac"

  zap trash: [
    "~/Library/Application Support/SpeedSentry",
    "~/Library/Preferences/app.speedsentry.mac.plist",
    "~/Library/Saved Application State/app.speedsentry.mac.savedState",
  ]
end
CASK
printf 'Generated %s for %s v%s\n' "$OUTPUT" "$REPOSITORY" "$VERSION"
