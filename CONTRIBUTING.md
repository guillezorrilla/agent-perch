# Contributing

Thanks for looking. This is a small, opinionated codebase — the notes below are
the conventions it already follows, not bureaucracy invented for newcomers.

## Getting set up

```sh
swift build          # debug
swift test           # the suite
make app             # assemble AgentPerch.app (release, signed)
open AgentPerch.app
```

macOS 14+, Apple Silicon. No other tooling required.

## The one rule that matters

**A card must never claim something the app hasn't verified.**

Most of the hard bugs in this project's history were the UI asserting something
plausible instead of something checked: a spinner that meant "recently touched"
rather than "a turn is in flight", a green dot on a session whose process had
exited, an "Approve" button that typed a digit meaning something bigger than the
label said.

If you're adding a state, an animation or a label, be able to answer: *what
evidence makes this true, and what happens when that evidence is missing?*
"Missing" is the case that bites.

## Pull requests

- **One concern per PR.** Small and reviewable beats complete.
- **Open an issue first** for anything non-obvious, and say what you measured.
  Several fixes here replaced a plausible theory that turned out to be wrong;
  the issue is where that gets caught cheaply.
- **Run all three gates locally before pushing** — CI runs them too, but knowing
  they pass before review is the norm here:

  ```sh
  swift test && swift build -c release && make app
  ```

- **Tests for anything with a branch in it.** The suite is fast (~2s); there is
  no excuse to skip it. If a test fixture has to change to accommodate your
  change, say *why* in the PR — a fixture edit that makes a failing assertion
  pass is exactly how a real regression gets waved through.
- **Comments explain why, not what.** The existing ones reference issue numbers
  so a future reader can find the failure that motivated the code. Keep that up.

## Cutting a release

Push a tag; the rest is automatic.

```sh
git tag v0.2.0 && git push origin v0.2.0
```

`.github/workflows/release.yml` runs the tests, imports the Developer ID cert into
a throwaway keychain, stamps the version *from the tag* into `Support/Info.plist`,
runs `make dmg`, and attaches the notarized DMG to the GitHub Release.

The tag is the only place a version number is authored. Don't hand-edit
`CFBundleShortVersionString` — the workflow overwrites it, and the update check
compares the tag against whatever the shipped bundle actually carries.

Five repo secrets feed it: `DEVELOPER_ID_P12` (base64 of the exported `.p12`),
`DEVELOPER_ID_P12_PASSWORD`, `APPLE_ID`, `APPLE_TEAM_ID`, `APPLE_APP_PASSWORD`.
The certificate expires **2027-02-01**; renewing it means a new export and two
updated secrets, no code change.

## Labels

Issues carry an `area:` label matching where the work lives — `jump`, `answer`,
`cards`, `discovery`, `hooks`, `usage`, `notch`, `packaging`. Pick the one you
would grep for.

Three others carry real meaning rather than decoration:

- **`regression`** — worked before, a change broke it. This project has re-broken
  the same areas more than once, so these get priority over new work.
- **`needs-decision`** — blocked on a product or design call, not on code. Do not
  start building one of these without settling the question in the issue first.
- **`needs-info`** — waiting on a repro, a log or a screenshot.

## Debugging

Prefer measurement to theory. The app logs to the `dev.agentperch` subsystem:

```sh
log stream --predicate 'subsystem == "dev.agentperch"' --level debug --style compact
```

Categories: `jump`, `answer`, `hover`, `usage-credentials`.

## Things that will bite you

- **`log` is a zsh builtin** — use `/usr/bin/log`.
- **Signing identity matters.** `make app` prefers a stable "Apple Development"
  identity and updates the bundle *in place*. Ad-hoc signing, or deleting the
  `.app` and recreating it, throws away the Accessibility and app-data grants
  the jump and answer paths depend on.
- **Releases are a different target.** `make dmg DEVELOPER_ID=… NOTARY_PROFILE=…`
  builds a *separate* bundle under `dist/`, signs it with the hardened runtime
  and notarizes it. It never touches your local `AgentPerch.app`, and it refuses
  to run rather than fall back to the development cert — that cert produces a
  DMG that fails Gatekeeper on every Mac but yours. Verify each release on a
  machine that has never run AgentPerch; quarantine is only set on downloads.
- **Hooks run detached.** A hook process has no controlling terminal, so it
  finds one by walking its parents. Don't assume `$$` has a tty.
