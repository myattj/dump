# Privacy

Last updated: July 17, 2026

Dump is designed around files stored on your Mac. It does not require a Dump account, and the source does not include a first-party analytics or advertising SDK. Some features deliberately send content to a model provider that you choose, and local search components may download model assets.

This document describes the behavior implemented by the public Dump source. Third-party services and tools have their own privacy terms.

## Data stored on your Mac

Dump may store the following locally:

- Captures, meeting notes, and extracted PDF text as Markdown under the storage root you choose. The default is `~/Dump`.
- YAML frontmatter containing identifiers, timestamps, titles, tags, entry type, status, scheduling data, queue metadata, and source references.
- A local qmd search index and derived embeddings under qmd's data directory, which Dump points at the selected storage root.
- Paths and index settings for code collections selected by you. Code folders are indexed in place rather than copied into Dump's content folders.
- Provider selection, model names, endpoint URLs, hotkeys, window positions, and other preferences in macOS UserDefaults.
- Anthropic and custom-provider API keys, plus AWS access credentials, in macOS Keychain. Keychain items are marked for this device and become accessible after the first unlock.
- Diagnostic logs under `~/Library/Logs/Dump`.
- Pending notification content managed by macOS, including an entry title, first-line preview, identifier, and local file path.

Imported PDFs are not copied into Dump. Dump stores extracted text and the original file path so it can refer back to the source. PDF import does not perform OCR.

## When content leaves your Mac

The selected provider is used for both capture classification and Ask-mode answer synthesis:

| Provider | Data sent |
| --- | --- |
| Anthropic | Captured text for classification; questions and retrieved snippets for answers |
| Claude Code or Codex | The same prompt content is passed to the configured local CLI, which may send it to its provider under your CLI login |
| OpenAI-compatible endpoint | Captured text, questions, and retrieved snippets are sent to the HTTPS endpoint you configure |
| Amazon Bedrock | Captured text, questions, and retrieved snippets are sent to the configured AWS Bedrock Runtime model |
| Ollama | Prompt content is sent to the configured Ollama server, which defaults to `127.0.0.1` |

Dump does not control how those providers retain or use submitted data. Review the provider's terms and privacy policy before sending sensitive material. A custom endpoint or non-local Ollama URL is controlled by whoever operates that server.

Capture is saved before classification. If no provider is available, the original Markdown file can still be written, while provider-derived metadata or answers may be unavailable.

## Local search and downloads

Dump launches its bundled qmd service on a free localhost port and communicates with it through local HTTP. The service binds to localhost by default. qmd performs indexing, embeddings, keyword search, semantic search, and reranking locally, but it may contact external model hosting services to download model assets when they are not already present.

Source builds also download:

- Node.js from `nodejs.org`
- qmd and its dependency tree from the npm registry
- Swift package dependencies from their configured Git repositories

These downloads expose ordinary network metadata, such as your IP address, to the relevant host.

## Updates

Dump uses Sparkle to check the public feed at:

`https://myattj.github.io/dump-updates/appcast.xml`

An update request exposes ordinary network metadata to GitHub's hosting infrastructure. Automatic update checks can be changed in Dump Settings.

## Diagnostics

Dump writes rotating local diagnostic files:

- `~/Library/Logs/Dump/dump.jsonl`
- `~/Library/Logs/Dump/network.jsonl`

Logs are capped at approximately 5 MB per file with up to three rotated backups. Network diagnostics record request category, method, host, a redacted path marker, status, timing, byte counts, and error codes. URL paths and query values are redacted, and request headers and bodies are not intentionally written to these files.

Other diagnostics can include qmd process output and error descriptions, which may themselves mention local paths or endpoint details. Review and redact logs before sharing them. Never post API keys, AWS credentials, private notes, or unreviewed logs in a public issue.

## Notifications

When you allow notifications, Dump schedules them through macOS UserNotifications. Notification titles and previews may be visible on your lock screen according to your macOS notification settings. Done and Snooze actions update the corresponding local Markdown entry.

## Retention and deletion

Dump keeps local content until you delete it. Removing the app does not automatically remove:

- Your selected Dump storage folder
- macOS UserDefaults for `com.joshmyatt.dump`
- Keychain items stored for `com.joshmyatt.dump`
- `~/Library/Logs/Dump`

You can delete notes with Finder or another editor, clear saved provider credentials in Settings, remove remaining Keychain items with Keychain Access, and delete logs with Finder. Deleting or moving indexed files can leave stale search data until qmd reindexes.

Third-party providers determine their own retention. Contact the relevant provider for deletion requests involving data sent to it.

## Changes and questions

This file will be updated when Dump's data handling materially changes.

For a general privacy question, open a GitHub issue without including private content. Report a privacy-related security vulnerability through the private process in [SECURITY.md](SECURITY.md).
