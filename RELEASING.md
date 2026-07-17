# Releasing Dump

Official releases are built from version tags by [the release workflow](.github/workflows/release.yml). A maintainer starts the workflow manually and supplies an existing tag. It runs the tests, signs every executable with Developer ID, submits the DMG to Apple's notary service, staples and validates the ticket, and publishes the DMG plus its SHA-256 checksum to GitHub Releases.

Source builds do not use these credentials and must not be presented as official releases.

## One-time GitHub setup

Create a `release` deployment environment and restrict it to the `main` branch. Manual workflow runs start from `main`, then check out and independently validate the requested version tag. Configure this environment variable:

| Variable | Example |
| --- | --- |
| `DEVELOPER_IDENTITY` | `Developer ID Application: Your Name (TEAMID)` |

Configure these environment secrets:

| Secret | Contents |
| --- | --- |
| `DEVELOPER_ID_P12_BASE64` | Base64-encoded Developer ID Application certificate and private key exported as PKCS#12 |
| `DEVELOPER_ID_P12_PASSWORD` | Password used when exporting the PKCS#12 file |
| `APPLE_NOTARY_KEY_P8` | Existing App Store Connect team API private key |
| `APPLE_NOTARY_KEY_ID` | App Store Connect API key ID |
| `APPLE_NOTARY_ISSUER_ID` | App Store Connect team issuer ID |

The GitHub CLI can set them without writing their values into the repository:

```bash
gh variable set DEVELOPER_IDENTITY --env release
base64 -i DeveloperIDApplication.p12 | gh secret set DEVELOPER_ID_P12_BASE64 --env release
gh secret set DEVELOPER_ID_P12_PASSWORD --env release
gh secret set APPLE_NOTARY_KEY_P8 --env release < AuthKey.p8
gh secret set APPLE_NOTARY_KEY_ID --env release
gh secret set APPLE_NOTARY_ISSUER_ID --env release
```

Follow [GitHub's certificate guidance](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications) when exporting the signing identity. Apple requires Developer ID signing, Hardened Runtime, secure timestamps, and notarization for directly distributed macOS software; see [Apple's notarization documentation](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).

The workflow deliberately has no unsigned fallback. Missing or invalid credentials stop the job before a release is published.

## Cut a release

1. Update `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `project.yml`. Every release needs a new build number, and the normal policy is to use a new marketing version too.
2. Update user-facing documentation and release notes as needed.
3. Run `./Scripts/build-local.sh --test` and merge the changes into `main`.
4. Tag the exact `main` commit using `v<version>-b<build>` and push the tag:

   ```bash
   git switch main
   git pull --ff-only
   git tag -a v0.1.3-b6 -m "Dump 0.1.3"
   git push origin v0.1.3-b6
   ```

5. Open **Actions → Release DMG → Run workflow**, enter the tag, and start the release.

The workflow verifies that the tag matches `project.yml` and belongs to `main`. It creates a draft release, attaches the verified artifacts, and only then publishes it as the latest release. A failed build may leave a draft, but it will never publish a partial release. Keeping this workflow manually triggered also prevents an unconfigured fork from failing merely because someone pushes a matching tag.

## Update the Sparkle feed

The canonical DMG lives in this repository's GitHub Release. Existing installations read their Sparkle feed from `https://myattj.github.io/dump-updates/appcast.xml`, so update that feed only after the GitHub Release is public.

Stage the existing `appcast.xml` and new notarized DMG together, then run:

```bash
RELEASE_DIR=/path/to/appcast-staging \
APPCAST_URL=https://myattj.github.io/dump-updates/appcast.xml \
DOWNLOAD_URL_PREFIX=https://github.com/myattj/dump/releases/download/v0.1.3-b6/ \
GENERATE_APPCAST=/path/to/generate_appcast \
./Scripts/release-appcast.sh
```

Use the existing Sparkle EdDSA private key matching `SUPublicEDKey` in `Resources/Info.plist`. Never generate a replacement key for an ordinary release: installed copies would reject updates signed by it. Review the generated enclosure URL, version, build, minimum system version, architecture, length, and signature before publishing `appcast.xml` to `dump-updates`.

Finally, install from the public DMG on a clean macOS account and exercise onboarding, capture, search, queue, notifications, and update checks.
