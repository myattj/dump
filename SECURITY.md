# Security policy

## Supported versions

Security fixes are made against the latest published release and the current `main` branch.

| Version | Supported |
| --- | --- |
| Latest published release | Yes |
| Older releases | No |

Update to the latest release before reporting a problem that may already be fixed.

## Report a vulnerability privately

Do not open a public issue for a suspected vulnerability.

Use [GitHub private vulnerability reporting](https://github.com/myattj/dump/security/advisories/new). Include:

- The affected Dump version and macOS version
- Whether you installed an official release or built from source
- A concise description of the impact
- Reproduction steps or a minimal proof of concept
- Relevant logs with notes, paths, credentials, tokens, and personal data removed
- Any suggested mitigation

Please give the maintainer a reasonable opportunity to investigate and publish a fix before sharing details publicly.

## Useful scope

Reports are especially useful when they involve:

- Unauthorized reading, modification, or disclosure of local notes
- Keychain credential handling
- Command or argument injection in qmd, Claude Code, or Codex process launches
- Exposure of the localhost qmd service
- Unsafe handling of custom provider URLs or network responses
- Sparkle update verification, signing, or release integrity
- Path traversal, unsafe file writes, or destructive storage behavior
- Sensitive information written to diagnostics

Problems that exist only in Anthropic, OpenAI-compatible services, AWS, Ollama, qmd, Node.js, Sparkle, or another dependency should normally be reported to that project's security contact. If Dump's integration makes the issue exploitable, report it here as well.

## Security model notes

- Dump is currently distributed as a non-sandboxed macOS app because it launches a bundled Node/qmd process and accesses user-selected files.
- qmd runs as a child process and serves MCP over a dynamically selected localhost port.
- Plan-backed mode launches the configured `claude` or `codex` executable and passes note-derived prompts to it.
- Custom model endpoints receive the prompt data described in [PRIVACY.md](PRIVACY.md).
- A source build is not an official release and does not inherit the maintainer's release signature or notarization.

These are intentional design boundaries, not blanket exclusions. A report showing that Dump crosses one unsafely is in scope.

## No bug bounty

Dump does not currently operate a paid bug bounty program. Please do not incur costs or access data that is not yours while testing.
