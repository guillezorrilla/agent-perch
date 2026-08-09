# VibeNotch

Free personal [Vibe Island](https://vibeisland.app/) clone: shows AI agent sessions (Claude Code, Codex, Antigravity) in the MacBook notch — click a session to jump to the terminal running it, get notified when an agent needs action.

Native Swift/SwiftUI, no dock icon, built on [DynamicNotchKit](https://github.com/MrKai77/DynamicNotchKit).

## Build

```sh
swift build          # debug build
swift test           # tests
make app             # assemble VibeNotch.app (release, ad-hoc signed)
open VibeNotch.app
```

Requires macOS 14+, Apple Silicon.

## Roadmap

- **M1** — Claude Code session cards in the notch (file watching), jump via tty match (iTerm2, Terminal.app), CI
- **M2** — Claude Code hooks: real-time working/needs-action/done, notifications with click-to-jump
- **M3** — Codex sessions (`codex resume`), tmux pane-level jump
- **M4** — Antigravity workspaces, Warp/cmux best-effort, settings
