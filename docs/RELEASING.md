# Publishing SpeedSentry

The selected source repository is `keshavbhardwaz/speedsentry`, with a formula in `keshavbhardwaz/homebrew-tap`. The initial distribution builds locally using Apple's Swift compiler. A precompiled signed cask can be added when a Developer ID certificate becomes available. Signing secrets must never be committed.

## Initial source release

Push this directory's contents as the root of the `speedsentry` repository. If it is inside another Git repository, use a dedicated checkout first. Review files and secret exclusions before the first push.

After the main branch passes CI, tag the exact commit to release:

```sh
git tag v0.1.0
git push origin v0.1.0
```

Only the read-only CI workflow is active. Source-release and signed-release workflows are stored as **inactive templates** in `docs/workflow-templates/`; GitHub does not run them there. The first release is published explicitly using authenticated GitHub CLI commands below. No Apple signing credentials are required for source distribution. Release tags must use `vX.Y.Z`; do not move a published tag to a different commit.

The formula must point at the real tagged source archive with its actual checksum. Generate it after the tag is available, publish the release, then copy it into the tap as **`Formula/speedsentry.rb`** and commit and push the tap.

```sh
brew install keshavbhardwaz/tap/speedsentry
speedsentry
```

The formula builds a native architecture `.app` directly with `xcrun swiftc`, signs it ad hoc locally, and installs it in Homebrew's Cellar. App builds do not require SwiftPM manifest evaluation; `Package.swift` remains for tests and IDE integration. Its launcher uses `opt_prefix`, Homebrew's stable symlink to the current version. It requires Swift 5.9+ from Apple's Command Line Tools or Xcode; a full Xcode installation is unnecessary if your CLT is current. Homebrew itself has separate [supported platform requirements](https://docs.brew.sh/Installation).

To generate the formula manually after the tag is live:

```sh
repository=keshavbhardwaz/speedsentry
version=0.1.0
mkdir -p dist
curl --fail --location --retry 3 \
  "https://github.com/$repository/archive/refs/tags/v$version.tar.gz" \
  --output "dist/SpeedSentry-$version-source.tar.gz"
checksum="$(shasum -a 256 "dist/SpeedSentry-$version-source.tar.gz" | awk '{print $1}')"
bash ./scripts/generate-formula.sh --repository "$repository" --version "$version" \
  --sha256 "$checksum" --output dist/Formula/speedsentry.rb
ruby -c dist/Formula/speedsentry.rb
```

Publish the initial source release explicitly after authenticating with `gh auth login`:

```sh
gh release create "v$version" "dist/SpeedSentry-$version-source.tar.gz" \
  dist/Formula/speedsentry.rb --repo "$repository" --verify-tag \
  --title "SpeedSentry $version" --generate-notes
```

If a release already exists, inspect its assets first; use `gh release upload` to add missing files without replacing published artifacts. The root-level source ZIP used during initial repository setup can be removed from the repository after the proper release asset is available.

Copy that file into the tap, then use `brew audit --formula keshavbhardwaz/tap/speedsentry`, `brew install --build-from-source keshavbhardwaz/tap/speedsentry`, and `brew test keshavbhardwaz/tap/speedsentry` on a clean Mac. Verify notification permission and login integration separately; an ad hoc identity can change between builds. Disable Launch at Login before an upgrade or uninstall, and re-enable it afterward if desired. Never publish a precompiled ad hoc app as a notarized release.

Homebrew's official [tap guide](https://docs.brew.sh/Taps) explains repository naming; the [Formula Cookbook](https://docs.brew.sh/Formula-Cookbook) covers source archives, dependencies, installation and tests.

## Future signed binary release

Create an Apple **Developer ID Application** certificate with its private key, and export a password-protected `.p12` from Keychain Access. In GitHub, configure an environment named `release` with these secrets:

| Secret | Value |
| --- | --- |
| `DEVELOPER_ID_P12_BASE64` | Base64-encoded exported `.p12` |
| `DEVELOPER_ID_P12_PASSWORD` | Password for that `.p12` |
| `DEVELOPER_ID_APPLICATION` | Full identity beginning `Developer ID Application:` |
| `APPLE_ID` | Apple developer account email |
| `APPLE_TEAM_ID` | Apple developer team identifier |
| `APPLE_APP_SPECIFIC_PASSWORD` | App-specific password for notarization |

The optional signed-release template is inactive at `docs/workflow-templates/release.yml`. To opt in later, review its write permissions and secret access, copy it to `.github/workflows/release.yml`, and commit that deliberate change. Then run **Signed macOS release** manually in GitHub Actions and supply the existing tag, for example `v0.1.0`. You can add required reviewers to the environment. The workflow tests, imports the identity into a temporary keychain, builds Apple silicon and Intel executables, combines them into a universal binary, signs with hardened runtime, submits using `notarytool`, staples Apple's ticket, and validates Gatekeeper assessment. It recreates the ZIP after stapling and checksums that exact ZIP. Credentials are removed in cleanup.

It adds `SpeedSentry-0.1.0-universal.zip`, its `.sha256`, and `speedsentry-cask.rb` to the release. Assets are not silently replaced. Copy the cask into the tap as `Casks/speedsentry.rb`, removing the formula of the same name when you migrate distribution, then install with:

```sh
brew install --cask keshavbhardwaz/tap/speedsentry
open -a SpeedSentry
```

Apple documents [Developer ID distribution and notarization](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution) and [customizing notarization](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow). Homebrew's [Cask Cookbook](https://docs.brew.sh/Cask-Cookbook) describes its checksum and installation rules.

For a local signed build, set `SIGNING_IDENTITY` to your certificate identity and `NOTARY_PROFILE` to an existing `notarytool` keychain credential profile, then run:

```sh
export VERSION=0.1.0
bash ./scripts/build-app.sh --universal --identity "$SIGNING_IDENTITY"
bash ./scripts/package-release.sh dist/SpeedSentry.app \
  "dist/SpeedSentry-$VERSION-universal.zip" --keychain-profile "$NOTARY_PROFILE"
```

The reusable cask generator accepts the real repository and exact final ZIP checksum:

```sh
repository=keshavbhardwaz/speedsentry
artifact="SpeedSentry-$VERSION-universal.zip"
checksum="$(shasum -a 256 "dist/$artifact" | awk '{print $1}')"
bash ./scripts/generate-cask.sh --repository "$repository" --version "$VERSION" \
  --artifact "$artifact" --sha256 "$checksum" --output dist/Casks/speedsentry.rb
```

## Upgrades and removal

For the source formula, run `brew update` then `brew upgrade keshavbhardwaz/tap/speedsentry`. Disable **Launch at Login**, quit the app, and run `brew uninstall keshavbhardwaz/tap/speedsentry` to remove it. History and settings are retained. The formula does not support cask `--zap`; delete local history deliberately after exporting it if needed.

For a future cask, standard removal also keeps history; `brew uninstall --cask --zap keshavbhardwaz/tap/speedsentry` removes local history and preferences. Export CSVs before `--zap` if you want to keep them.

## Optional automation templates

`docs/workflow-templates/source-release.yml` can automate future source releases, and `release.yml` can add signed binaries. Both request `contents: write` and remain inactive. Review and explicitly enable a template by copying it into `.github/workflows/` only when you want that publishing behavior. Keeping them as documentation leaves active CI with `contents: read`.
