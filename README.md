# Dump for macOS

Capture thoughts in a keystroke. Keep them as Markdown. Find them when they matter.

[![CI](https://github.com/myattj/dump/actions/workflows/ci.yml/badge.svg)](https://github.com/myattj/dump/actions/workflows/ci.yml)
[![Latest release](https://img.shields.io/github/v/release/myattj/dump?label=download&sort=semver)](https://github.com/myattj/dump/releases/latest)
![macOS 14+](https://img.shields.io/badge/macOS-14%2B-000000?logo=apple)
![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-arm64-000000?logo=apple)
![Swift 6](https://img.shields.io/badge/Swift-6.0-F05138?logo=swift&logoColor=white)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

Dump is a native macOS menu bar app for quickly capturing notes, tasks, reminders, ideas, and references. It writes your captures to ordinary Markdown files, builds a local search index with [qmd](https://github.com/tobi/qmd), and gives you a ranked queue for deciding what to do next.

Dump is open source under the [MIT License](LICENSE).

## What Dump does

- **Capture from anywhere.** Press `⇧⌘D`, type, and submit without changing apps.
- **Keep durable files.** Captures are Markdown with readable YAML frontmatter in a folder you control.
- **Turn natural language into structure.** Dump can identify entry type, title, tags, dates, effort, and priority through your selected model provider.
- **Work from a ranked queue.** Tasks rise based on deadlines, reminder times, effort, importance, age, and snoozes.
- **Search and ask.** Press `⇧⌘F` for local keyword and semantic search, or ask a configured model to answer from the retrieved snippets with citations.
- **Bring in more context.** Capture meeting notes, extract text from PDFs, and index selected code folders in place.
- **Get actionable reminders.** Scheduled entries use macOS notifications with Done and Snooze actions.
- **Choose the model path.** Use Anthropic, an authenticated Claude Code or Codex CLI, an OpenAI-compatible endpoint, Amazon Bedrock, or Ollama.

Capture is written to disk before model classification and indexing. A provider failure should not cost you the original note.

## Requirements

- macOS 14 Sonoma or later
- Apple silicon (`arm64`)

Intel Macs and universal binaries are not supported.

Model requirements depend on the provider you choose during onboarding. Ollama and the plan-backed options require their respective local tools to be installed and configured separately.

## Download and install

**[Download the latest DMG](https://github.com/myattj/dump/releases/latest)**

Official release DMGs are signed with Developer ID and notarized by Apple.

1. Download the DMG from the latest release.
2. Open the DMG and drag Dump into Applications.
3. Open Dump from Applications. It appears in the menu bar rather than the Dock.
4. Complete onboarding and choose a classifier and answer provider.

Dump uses Sparkle for update checks. Automatic checks can be changed in Settings.

## Quick start

| Action | Default shortcut |
| --- | --- |
| Capture | `⇧⌘D` |
| Search or ask | `⇧⌘F` |
| Open the queue | `⇧⌘T` |
| New meeting note | Configure in Settings |

Shortcuts can be changed or disabled in Settings.

Try captures such as:

```text
Remind me to submit the report tomorrow at 9am
Review the onboarding copy Friday ~30m !!
Idea: make the empty state explain the first action
```

Dump understands common date phrases, explicit effort such as `30m` or `2h`, and priority signals such as `!`, `!!`, `urgent`, or `low priority`. Your configured model can enrich the deterministic parser with titles, tags, and other metadata.

## Where your data lives

The default storage root is `~/Dump`. You can choose another folder in Settings.

```text
~/Dump/
├── inbox/       # captures, tasks, and reminders
├── meetings/    # meeting notes
└── pdfs/        # extracted PDF text, one Markdown file per readable page
```

Each file contains a stable ID, timestamps, status, source, tags, and any available scheduling or queue metadata. The body remains plain text Markdown.

PDF import extracts text that is already present in the document. Dump does not perform OCR, and it does not copy the original PDF into the storage root. Code collections are indexed from their selected folders rather than copied into Dump.

## Search and model providers

Search indexing and retrieval run through the bundled qmd process on your Mac. Answer synthesis and automatic classification use the provider selected in Settings.

| Provider | Setup | Where prompts go |
| --- | --- | --- |
| Anthropic | Anthropic API key | Anthropic or your configured Anthropic-compatible proxy |
| Claude Code / Codex | Installed and authenticated official CLI | The local CLI, which may contact its provider using your existing login |
| OpenAI-compatible | HTTPS base URL, model names, API key | The endpoint you configure |
| Amazon Bedrock | Region, model IDs, AWS credentials | AWS Bedrock Runtime |
| Ollama | Ollama server and a pulled model | The configured Ollama server, `127.0.0.1` by default |

For classification, Dump sends the captured text to the selected provider. For Ask mode, it sends your question plus the top retrieved snippets. API keys and AWS credentials are stored in macOS Keychain; non-secret settings such as model names and executable paths are stored in UserDefaults.

Read [PRIVACY.md](PRIVACY.md) before using Dump with sensitive notes or third-party model providers.

## Build from source

### Prerequisites

- An Apple-silicon Mac running macOS 14 or later
- The full Xcode 16 app or newer, with Swift 6 support
- [Homebrew](https://brew.sh/) for installing [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- Network access for Swift packages, Node.js, qmd, and qmd model assets

### Build and open Dump

```bash
git clone https://github.com/myattj/dump.git
cd dump
brew install xcodegen
./Scripts/build-local.sh --open
```

The script generates the Xcode project, downloads the pinned runtime dependencies, and builds Dump at `build/local/Dump.app`. The first build requires network access and may take longer while those dependencies are downloaded.

Local builds are ad-hoc signed for development. They are not official releases and do not carry the maintainer's Developer ID signature or Apple notarization ticket.

### Run the tests

```bash
./Scripts/build-local.sh --test
```

The `--test` option runs the unit tests before creating the Release build. It can be combined with `--open`.

`project.yml` is the source of truth for the Xcode project. `Dump.xcodeproj`, the downloaded Node runtime, qmd's installed packages, and build output are generated locally and intentionally ignored by Git.

To work in Xcode after generation:

```bash
open Dump.xcodeproj
```

Release signing, notarization, and Sparkle publication require maintainer credentials. Contributors do not need those credentials to build and test locally. Maintainers can follow [RELEASING.md](RELEASING.md).

## Project layout

```text
App/
  Capture/       global hotkeys, capture UI, PDF import
  Classifier/    metadata extraction provider clients
  Daemon/        bundled qmd process and MCP transport
  Query/         search, answer synthesis, citations
  Queue/         queue persistence, ranking, and UI
  Scheduler/     macOS notification scheduling and actions
  Settings/      onboarding, provider settings, Keychain access
  Storage/       Markdown and frontmatter persistence
  Updates/       Sparkle integration
Resources/       app metadata and entitlements
Runtime/qmd/     pinned qmd dependency manifest
Scripts/         runtime, build, signing, and release automation
Tests/           XCTest coverage
```

The app uses SwiftUI for most UI, AppKit where macOS window behavior requires it, and strict Swift 6 concurrency checks.

## Contributing and support

Read [CONTRIBUTING.md](CONTRIBUTING.md) before participating. Bug reports, focused feature requests, documentation improvements, and pull requests are welcome. Do not include private notes, credentials, or unredacted logs.

Security reports belong in GitHub's private vulnerability reporting flow. See [SECURITY.md](SECURITY.md).

## Third-party software

Dump bundles or links software maintained by other projects. Versions, copyright notices, and license information are listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## License

Dump is available under the [MIT License](LICENSE).
