# Contributing to Dump

Thanks for helping make Dump better. Reproducible bug reports, focused feature proposals, and documentation feedback are welcome.

The repository is publicly viewable but is not open source. Read [LICENSE](LICENSE) before using or contributing code.

External code contributions are accepted only by prior written arrangement with the maintainer. Please open an issue before preparing a pull request; unsolicited code pull requests may be closed. The development guidance below applies to invited contributions and maintainer work.

## Before you start

- Search existing issues before opening a new one.
- Open an issue before investing in a large feature or architectural change.
- Report vulnerabilities privately using [SECURITY.md](SECURITY.md).
- Do not include real notes, credentials, private paths, or unredacted diagnostics in issues, commits, fixtures, or screenshots.

## Development requirements

- Apple-silicon Mac
- macOS 14 or later
- Xcode 16 or later with Swift 6 support
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- Network access for the pinned runtime and package dependencies

Install XcodeGen and prepare a checkout:

```bash
brew install xcodegen
git clone https://github.com/myattj/dump.git
cd dump
xcodegen generate
./Scripts/fetch-runtime.sh
```

`project.yml` is the Xcode project source of truth. Do not commit generated `Dump.xcodeproj` content.

## Run the tests

```bash
xcodebuild \
  -project Dump.xcodeproj \
  -scheme Dump \
  -destination 'platform=macOS,arch=arm64' \
  test
```

For a focused XCTest run, add `-only-testing:DumpTests/TestClassName`.

CI runs on an Apple-silicon macOS runner. A pull request should pass the same test command without signing or notarization credentials.

## Make a change

1. Create a focused branch from `main`.
2. Keep the change small enough to review.
3. Add or update tests for observable behavior.
4. Update documentation when setup, storage, privacy, provider behavior, or user-facing features change.
5. Run the relevant tests locally.
6. Open a pull request using the repository template.

## Code expectations

- Preserve strict Swift 6 concurrency checking and explicit actor boundaries.
- Keep durable user data in the Markdown/frontmatter layer unless a migration is included.
- Treat capture durability as more important than classification or indexing.
- Keep provider-specific behavior behind the existing classifier and synthesizer abstractions.
- Avoid adding a dependency without discussing its runtime size, licensing, update path, and privacy impact.
- Keep UI accessible with keyboard navigation, VoiceOver labels, sufficient contrast, and Reduce Motion behavior.
- Use representative synthetic data in tests.

Generated and local-only artifacts should remain untracked:

- `Dump.xcodeproj`
- `Runtime/node/`
- `Runtime/qmd/node_modules/`
- `build/` and `DerivedData/`
- signing credentials, provisioning profiles, and environment files

## Release tooling

The scripts in `Scripts/` cover runtime fetching, Developer ID signing, notarization, DMG creation, and Sparkle appcast generation. Release operations require maintainer-owned Apple and Sparkle credentials. Do not add credentials or generated release artifacts to a pull request.

Do not submit third-party code unless its license permits the proposed use and its required notices are included. Any contribution terms will be agreed in writing before code is accepted.
