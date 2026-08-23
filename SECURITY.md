# Security

## Reporting

Please report vulnerabilities privately through
[GitHub's advisory form](https://github.com/guillezorrilla/agent-perch/security/advisories/new)
rather than opening a public issue.

## What this app touches

Worth stating plainly, because it is more than a notch widget needs and a
reviewer should know where to look:

- **Keychain.** Reads the `Claude Code-credentials` item in-process to show
  quota. The token is held in memory for the lifetime of the process and is
  sent only to Anthropic's usage endpoint. It is never written to disk or
  logged — see `RuntimeUsageTokenSource`.
- **Accessibility.** Used to post keystrokes so a card can be answered in the
  terminal it belongs to. This is the strongest permission the app asks for; it
  is optional, and declining it only disables answering.
- **Other apps' containers.** Reads Warp's sqlite (copied first, read-only) to
  find which tab a session is in. Nothing is written back.
- **Transcripts.** Reads agent session files under `~/.claude`, `~/.codex` and
  similar to build the session list. These contain your prompts.

## What it does not do

No network requests other than the provider usage endpoints. No telemetry, no
analytics, no crash reporting. Session titles, prompts and file paths stay on
the machine.

If a change would alter any line above, say so explicitly in the pull request.
