# Dashi

A small macOS **menu bar** app that shows your **Claude** and **Codex** subscription usage limits at
a glance — click the menu bar icon to see how much of each rolling window you've used and when it
resets, without opening Claude Code or the Codex CLI. Dashi shows whichever windows each provider
reports: **Claude**'s 5-hour and weekly, and **Codex**'s weekly (Codex has retired its 5-hour
window). The menu bar shows whichever provider you're closest to your limit on.

> macOS only for now. Native Swift + SwiftUI (`MenuBarExtra`).

## Install

Requires **macOS 14 or later**.

1. Download **`Dashi-0.3.1.dmg`** from the
   [latest release](https://github.com/ThugipanSivanesan/Dashi/releases/latest).
2. Open the `.dmg` and drag **Dashi** into **Applications**.
3. **First launch:** Dashi is an unsigned community build (not Apple-notarized), so macOS Gatekeeper
   blocks it the first time. Open **System Settings → Privacy & Security**, scroll down, and click
   **"Open Anyway"** (on macOS 15 Sequoia the Control-click → Open shortcut no longer bypasses
   Gatekeeper). Or clear the quarantine flag yourself:
   ```sh
   xattr -dr com.apple.quarantine /Applications/Dashi.app
   ```

Dashi runs in the **menu bar** (no Dock icon) — click its icon to see your usage. The gauges reuse
Claude Code's and the Codex CLI's local logins; see [Privacy](#privacy) for the personal-use / ToS
note. A `.zip` and a Homebrew cask are also published for signed releases (in-app updates via
Sparkle) — see [RELEASING.md](RELEASING.md).

**Verify your download** (optional, recommended) against the published checksum:

```sh
shasum -a 256 -c Dashi-0.3.1.dmg.sha256
```

### Install & update with Homebrew

Prefer Homebrew? Install from the tap:

```sh
brew tap ThugipanSivanesan/tap
brew install --cask dashi
```

Then upgrade to future releases with:

```sh
brew upgrade --cask dashi
```

(These are still unsigned community builds, so the first launch is Gatekeeper-blocked — clear the
quarantine as shown above if macOS refuses to open it.)

## For AI assistants (LLMs)

Don't want to do it by hand? Copy the prompt below and paste it to your AI assistant
(Claude Code, or any agent that can run shell commands on your Mac) — it will install Dashi for you:

**Install the Dashi macOS menu-bar app for me.**

```text
Install the Dashi macOS menu-bar app from its GitHub release. Do this on my Mac:

1. Check I'm on macOS 14 or later; stop and tell me if I'm not.
2. Make sure the GitHub CLI is installed and authenticated — run `gh auth status`
   (if `gh` is missing, install it with `brew install gh` and have me run `gh auth login`).
3. Download the release DMG:
   gh release download v0.3.1 --repo ThugipanSivanesan/Dashi --pattern 'Dashi-*.dmg' --dir /tmp --clobber
4. Mount it, copy Dashi.app into /Applications, then unmount:
   MNT="$(hdiutil attach -nobrowse -readonly /tmp/Dashi-0.3.1.dmg | awk -F'\t' 'END{print $NF}')"
   cp -R "$MNT/Dashi.app" /Applications/
   hdiutil detach "$MNT"
5. It's an unsigned build, so clear the Gatekeeper quarantine so it will launch:
   xattr -dr com.apple.quarantine /Applications/Dashi.app
6. Launch it with `open -a Dashi` and tell me to look for the Dashi icon in the menu bar.

Show me each command before you run it, and stop if any step fails.
```

To build from source instead, see [Development](#development) (`bash Scripts/make-dmg.sh`).

## Status

- **Shipped:** Claude and Codex usage gauges — each shows whichever rolling windows the provider
  reports (Claude's 5-hour and weekly; Codex now reports only a weekly window — its 5-hour window
  has been retired), read from the local Claude Code / Codex CLI OAuth token (personal use — see
  [Privacy](#privacy)).
- **Roadmap:** refresh/threshold alerts, and a multi-provider Admin-API usage/cost dashboard.

## Why the percentage can differ from `/usage`

Dashi reads the **same** number as Claude Code's `/usage` — the identical
`api.anthropic.com/api/oauth/usage` endpoint, using the server's already-computed
`utilization` value with no math of its own. If the two ever disagree, it's not a
different calculation — it's one of two things:

- **Dashi's reading is a little stale.** To stay well under the providers' rate
  limits, Dashi refreshes on an interval (and backs off further after a `429`),
  meanwhile showing the last good reading rather than flashing an error. Because
  the 5-hour and weekly windows are **rolling**, older usage keeps aging out, so
  the live number drifts down between refreshes — which can leave Dashi a few
  points *higher* than a `/usage` you just ran. It re-syncs on the next fetch;
  open the popup to pull a fresh reading.
- **You're comparing different windows.** The menu-bar number is the provider's
  shortest reported window — the **5-hour** window for Claude, and the **weekly**
  window for Codex (which no longer has a 5-hour window). `/usage` prints every
  window a provider exposes, so make sure you're comparing like for like — the
  Dashi popup shows each reported window side by side.

## Architecture

| Target       | Role                                                                          |
| ------------ | ----------------------------------------------------------------------------- |
| `DashiCore`  | All testable logic: config, secret-safe types, Keychain, redaction, providers |
| `Dashi`      | Thin SwiftUI `MenuBarExtra` app (no Dock icon) that renders `DashiCore` data  |

Each gauge is a `LimitProvider` (`ClaudeSubscriptionProvider`, `CodexSubscriptionProvider`) that
reads a locally-stored OAuth token and returns the rolling-window `SubscriptionLimits`; the network
transport is injected so the whole path is unit-tested without hitting the network. A separate
`UsageProvider`/`ProviderMode` track (offline stub by default) scaffolds the roadmap usage/cost
dashboard. See `Sources/DashiCore`.

## Privacy

Dashi talks **only to the AI providers' own APIs**, directly from your Mac — **no telemetry, no
analytics, no "phone home."** Your usage figures and credentials never leave your machine. The
gauges reuse the OAuth tokens Claude Code (Keychain) and the Codex CLI (`~/.codex/auth.json`)
already store locally — **read-only, never copied, written back, or logged**; note this is a
**personal-use, ToS grey-area** feature. Full details, the threat model, and how to revoke access
are in **[SECURITY.md](SECURITY.md)**.

## Security

- **Secrets never enter git.** Credentials live in the **macOS Keychain**, never in a file. `.env`
  holds non-secret config only.
- Defense-in-depth: a non-printing `Secret` wrapper, a secret-redacting log filter (`Redactor`),
  `gitleaks` in pre-commit **and** CI, and an `osv-scanner` dependency scan.
- CI is least-privilege (`contents: read`), all actions are SHA-pinned, and runs on PRs + a weekly
  schedule.
- Reporting a vulnerability and the full security model: see **[SECURITY.md](SECURITY.md)**.
- Cutting a distributable build? Sign + notarize per **[RELEASING.md](RELEASING.md)**.

## Development

Requires macOS with **Xcode** installed (the Command Line Tools alone lack XCTest).

```sh
# one-time
pre-commit install

# the full local gate (format-lint + build + test) — mirrors CI
bash Scripts/check.sh

# run the app (quick dev loop)
swift run Dashi

# build the distributable Dashi.app bundle (needs XcodeGen: brew install xcodegen)
bash Scripts/build-app.sh

# package an unsigned (ad-hoc signed) .dmg and/or Sparkle .zip → dist/Dashi-<version>.{dmg,zip}
# (needs create-dmg: brew install create-dmg)
bash Scripts/make-dmg.sh
bash Scripts/make-zip.sh
```

The Xcode app target is generated from `project.yml` (XcodeGen); the `.xcodeproj` is gitignored. It
links **Sparkle** for in-app auto-updates (inert until an update-signing key is configured). See
[RELEASING.md](RELEASING.md) for signing, notarization, the Sparkle appcast, and the Homebrew cask.

## Contributing

Every change ships as a small, tested, green slice via a feature branch and PR (see
`Scripts/check.sh` and the CI workflow). `main` is always releasable.

## Acknowledgements

Dashi's reading of the local Claude Code OAuth credentials — the
`Claude Code-credentials` Keychain item, the `~/.claude/.credentials.json`
fallback, the `claudeAiOauth` token envelope, and the `oauth-2025-04-20` beta
header — was informed by
[griffinmartin/opencode-claude-auth](https://github.com/griffinmartin/opencode-claude-auth)
(MIT), an OpenCode plugin that authenticates with existing Claude Code
credentials. Dashi only _reads_ usage; it does not refresh tokens.

## License

MIT — see [LICENSE](LICENSE).
