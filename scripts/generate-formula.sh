#!/bin/bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: bash scripts/generate-formula.sh --repository OWNER/REPO --version X.Y.Z
       --sha256 SOURCE_TARBALL_SHA256 --output PATH
The checksum must match https://github.com/OWNER/REPO/archive/refs/tags/vX.Y.Z.tar.gz.
USAGE
}
REPOSITORY=""
VERSION=""
SHA256=""
OUTPUT=""
while (($#)); do
  (($# >= 2)) || { usage >&2; exit 2; }
  case "$1" in
    --repository) REPOSITORY="$2" ;;
    --version) VERSION="$2" ;;
    --sha256) SHA256="$2" ;;
    --output) OUTPUT="$2" ;;
    *) usage >&2; exit 2 ;;
  esac
  shift 2
done
[[ "$REPOSITORY" =~ ^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { echo 'Invalid GitHub OWNER/REPO.' >&2; exit 2; }
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Version must be X.Y.Z.' >&2; exit 2; }
[[ "$SHA256" =~ ^[A-Fa-f0-9]{64}$ ]] || { echo 'SHA-256 must contain 64 hex digits.' >&2; exit 2; }
[[ -n "$OUTPUT" ]] || { usage >&2; exit 2; }
mkdir -p "$(dirname "$OUTPUT")"
cat > "$OUTPUT" <<FORMULA
class Speedsentry < Formula
  desc "Menu bar download speed monitor with alerts and IST incident history"
  homepage "https://github.com/$REPOSITORY"
  url "https://github.com/$REPOSITORY/archive/refs/tags/v$VERSION.tar.gz"
  sha256 "$SHA256"
  license "MIT"

  depends_on macos: :ventura
  uses_from_macos "swift" => :build

  def install
    swift_version = Utils.safe_popen_read("xcrun", "swift", "--version")[/Swift version (\d+\.\d+)/, 1]
    if swift_version.nil? || Version.new(swift_version) < Version.new("5.9")
      odie "Swift 5.9+ is required. Install current Xcode Command Line Tools with xcode-select --install."
    end

    ENV["VERSION"] = version.to_s
    ENV["CLANG_MODULE_CACHE_PATH"] = (buildpath/".build/clang-module-cache").to_s
    # This dependency-free app compiles directly, bypassing SwiftPM manifest evaluation.
    system "bash", "./scripts/build-app.sh"
    prefix.install "dist/SpeedSentry.app"
    (bin/"speedsentry").write <<~SH
      #!/bin/sh
      exec /usr/bin/open "#{opt_prefix}/SpeedSentry.app" --args "\$@"
    SH
    chmod 0755, bin/"speedsentry"
  end

  def caveats
    <<~EOS
      Start the menu bar app with: speedsentry
      This formula compiles locally with an ad hoc signature; no Apple Developer ID is required.
      The app stays in Homebrew's Cellar and opens through its stable opt path.
      Disable Launch at Login before upgrading or uninstalling, then enable it again if needed.
      Check macOS Notifications settings if alerts are missing.
      Uninstalling keeps history at ~/Library/Application Support/SpeedSentry.
    EOS
  end

  test do
    assert_path_exists prefix/"SpeedSentry.app/Contents/MacOS/SpeedSentry"
    assert_match "app.speedsentry.mac", shell_output("/usr/bin/plutil -extract CFBundleIdentifier raw '#{prefix}/SpeedSentry.app/Contents/Info.plist'")
    system "/usr/bin/codesign", "--verify", "--strict", prefix/"SpeedSentry.app"
    assert_match "#{opt_prefix}/SpeedSentry.app", (bin/"speedsentry").read
  end
end
FORMULA
printf 'Generated %s for %s v%s\n' "$OUTPUT" "$REPOSITORY" "$VERSION"
