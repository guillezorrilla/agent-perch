# Vibe Island M2b Design

## Scope

Replace the current compact and expanded presentation with the Vibe Island skin, add actionable permission and plan cards, show OAuth usage while expanded, and expose panel width and needs-action dwell settings. Preserve SwiftPM, DynamicNotchKit, the current session lifecycle, display modes, terminal jump behavior, and hook installation workflow.

## Architecture

`SessionStore` remains the only session-state authority. A pending hook action is derived from each session's `pendingToolName` and `pendingToolInput`; subsequent `UserPromptSubmit`, `Stop`, or `PreToolUse` replaces or clears that state in the store.

Pure helpers parse pending tool input, build bounded diff previews, extract plan Markdown, and select terminal injection commands. Runtime side effects live in one `ActionInjector` and one injected `UsageProvider`. SwiftUI views consume these values without performing parsing or process work.

## Presentation

DynamicNotchKit continues to own notch presentation. Compact leading content renders the 11 by 8 Canvas invader and active title; compact trailing content renders the session count. Expanded content uses the configured 440 to 800 point width, a conditional usage strip, one featured session or pending-action card, and compact remaining rows. Every session surface jumps through the existing `Jumper`.

The first needs-action session is featured, otherwise the newest session is featured. Permission and plan cards replace only a featured needs-action session that has matching pending input. SwiftUI command shortcuts trigger the same allow or deny closures as the buttons.

## Usage

`UsageProvider` receives a token source and URL-loading protocol. The runtime token source tries the macOS `security` command, then `~/.claude/.credentials.json`. The provider calls the Anthropic OAuth usage endpoint on expansion and every 120 seconds while the expanded view exists. It publishes parsed five-hour and seven-day windows and silently hides the strip when no valid response is available.

## Actions

`ActionInjector` maps iTerm, tmux, and Terminal sessions to their required runtime commands. Allow sends `1`; deny sends Escape. Unknown terminals and runtime failures return false, causing the view to use `Jumper.jump` for manual response. Tests exercise only pure command mapping and injected parsers, never real terminals, credentials, Keychain, Claude files, or network.

## Testing and Verification

Add focused XCTest coverage for diff counts and truncation, usage JSON, credential JSON, terminal action mapping, hook matcher migration, plan extraction, and pending-state clearing. Run `swift build -c release`, `swift test`, `make app`, and read-only `git status --short`, recording each exit code.

## Constraints

- No new dependencies or Xcode project.
- No git writes.
- No test access to real Claude state, credentials, Keychain, terminals, or network.
- No changes outside this repository.
