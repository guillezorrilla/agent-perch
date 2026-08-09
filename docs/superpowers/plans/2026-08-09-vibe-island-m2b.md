# Vibe Island M2b Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver the M2b Vibe Island skin, actionable permission and plan cards, usage strip, and settings in the existing SwiftPM macOS app.

**Architecture:** Keep `SessionStore` authoritative and derive presentation models through pure helpers. Isolate runtime usage loading and terminal injection behind protocols or pure mappings, while focused SwiftUI views render the resulting state.

**Tech Stack:** Swift 5 language mode, SwiftUI, AppKit, Foundation, XCTest, SwiftPM, DynamicNotchKit.

## Global Constraints

- No git writes, new dependencies, network calls in tests, or Xcode project.
- Tests must not touch real `~/.claude`, Keychain, or terminal sessions.
- Runtime credential and terminal automation paths are allowed.
- Keep current display modes, settings, hooks, and Jumper behavior working.

---

### Task 1: Pure M2b models and state lifecycle

**Files:**
- Create: `Sources/VibeNotch/Models/PendingAction.swift`
- Modify: `Sources/VibeNotch/Models/HookEvent.swift`
- Modify: `Sources/VibeNotch/SessionStore.swift`
- Create: `Tests/VibeNotchTests/M2bModelTests.swift`
- Modify: `Tests/VibeNotchTests/HookEventTests.swift`

**Interfaces:**
- Produces: `PendingAction.parse(toolName:input:)`, `DiffPreview.build(removed:added:limit:)`, and cleared pending state after later lifecycle events.

- [ ] Write tests for edit/write diff counts, eight-line truncation, ExitPlanMode Markdown extraction, and pending-state clearing.
- [ ] Run the focused tests and confirm they fail because the new helpers and clearing behavior are absent.
- [ ] Implement the smallest pure models and shared store changes.
- [ ] Run the focused tests and the full suite.

### Task 2: Usage provider

**Files:**
- Create: `Sources/VibeNotch/Usage/UsageProvider.swift`
- Create: `Tests/VibeNotchTests/UsageProviderTests.swift`

**Interfaces:**
- Produces: `UsageSnapshot.parse(_:)`, `CredentialParser.accessToken(from:)`, `UsageTokenSource`, `UsageLoading`, and `UsageProvider.refresh()`.

- [ ] Write fixture-based tests for usage and credential JSON parsing.
- [ ] Run the focused tests and confirm missing-type failures.
- [ ] Implement injected runtime token and URLSession paths with silent failure.
- [ ] Run the focused tests and the full suite.

### Task 3: Action injection

**Files:**
- Create: `Sources/VibeNotch/Actions/ActionInjector.swift`
- Create: `Tests/VibeNotchTests/ActionInjectorTests.swift`

**Interfaces:**
- Produces: `ActionInjector.plan(terminalName:tty:decision:)` and `inject(_:into:)`.
- Consumes: `AgentSession`, `AppleScriptRunner.shellQuote`, and `AppleScriptRunner.stringLiteral`.

- [ ] Write tests for allow and deny mapping across iTerm, tmux, Terminal, and unknown terminals.
- [ ] Run the focused tests and confirm missing-type failures.
- [ ] Implement the pure mapping plus runtime AppleScript/tmux execution.
- [ ] Run the focused tests and the full suite.

### Task 4: Hook matcher migration

**Files:**
- Modify: `Sources/VibeNotch/Hooks/HookInstaller.swift`
- Modify: `Tests/VibeNotchTests/HookTests.swift`

**Interfaces:**
- Produces: exact `Edit|MultiEdit|Write|Bash|NotebookEdit|ExitPlanMode` matcher and replace-style migration.

- [ ] Update tests to require the new matcher and replacement of an old installed matcher.
- [ ] Run the focused tests and confirm matcher failures.
- [ ] Centralize and apply the new matcher in install and detection.
- [ ] Run the focused tests and the full suite.

### Task 5: Vibe Island views and settings

**Files:**
- Create: `Sources/VibeNotch/UI/InvaderGlyph.swift`
- Modify: `Sources/VibeNotch/UI/NotchContentView.swift`
- Modify: `Sources/VibeNotch/UI/SessionCardView.swift`
- Modify: `Sources/VibeNotch/Settings/AppSettings.swift`
- Modify: `Sources/VibeNotch/Settings/SettingsWindow.swift`
- Modify: `Sources/VibeNotch/AppDelegate.swift`

**Interfaces:**
- Consumes: `PendingAction`, `UsageProvider`, `ActionInjector`, `Jumper`, and `AppSettings`.
- Produces: compact capsule halves, conditional usage strip, featured/action cards, remaining rows, panel-width binding, and configurable dwell behavior.

- [ ] Implement the hardcoded Canvas glyph and replace compact content.
- [ ] Implement usage, featured, permission, plan, and remaining-session views using native SwiftUI.
- [ ] Wire panel width, dwell settings, refresh lifetime, shortcuts, jump fallback, and auto-expand timing.
- [ ] Run `swift test` and `swift build -c release`, fixing compile or regression failures at their source.

### Task 6: Release verification

**Files:**
- Modify only files required to correct failures found by the mandated gates.

- [ ] Run `swift build -c release` and record exit code.
- [ ] Run `swift test` and record exit code.
- [ ] Run `make app` and record exit code.
- [ ] Run read-only `git status --short` and confirm every path is repository-internal.
- [ ] Re-read the original M2b brief and report coverage, decisions, files, outputs, exit codes, and `blocked_on`.
