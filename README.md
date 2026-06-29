# Dashi

A small macOS **menu bar** app that shows your Claude subscription's **5-hour usage limit** at a
glance — click the menu bar icon to see how much of the rolling window you've used and when it
resets, without opening Claude. A multi-provider usage/cost dashboard (Anthropic, OpenAI) is on the
roadmap.

> macOS only for now. Native Swift + SwiftUI (`MenuBarExtra`).

## Install

Requires **macOS 14 or later**.

1. Download **`Dashi-0.1.0.dmg`** from the
   [latest release](https://github.com/ThugipanSivanesan/Dashi/releases/latest).
2. Open the `.dmg` and drag **Dashi** into **Applications**.
3. **First launch:** Dashi is an unsigned community build (not Apple-notarized), so macOS Gatekeeper
   blocks it the first time. Open **System Settings → Privacy & Security**, scroll down, and click
   **"Open Anyway"** (on macOS 15 Sequoia the Control-click → Open shortcut no longer bypasses
   Gatekeeper). Or clear the quarantine flag yourself:
   ```sh
   xattr -dr com.apple.quarantine /Applications/Dashi.app
   ```

Dashi runs in the **menu bar** (no Dock icon) — click its icon to see your usage. The Claude gauge
reuses Claude Code's local login; see [Privacy](#privacy) for the personal-use / ToS note.

**Verify your download** (optional, recommended) against the published checksum:

```sh
shasum -a 256 -c Dashi-0.1.0.dmg.sha256
```

## For AI assistants (LLMs)

Don't want to do it by hand? Copy the prompt below and paste it to your AI assistant
(Claude Code, or any agent that can run shell commands on your Mac) — it will install Dashi for you:

> Install the **Dashi** macOS menu-bar app from its GitHub release. Do this on my Mac:
>
> 1. Check I'm on **macOS 14 or later**; stop and tell me if I'm not.
> 2. Make sure the GitHub CLI is installed and authenticated — run `gh auth status` (if `gh` is
>    missing, install it with `brew install gh` and have me run `gh auth login`).
> 3. Download the release DMG:
>    `gh release download v0.1.0 --repo ThugipanSivanesan/Dashi --pattern 'Dashi-*.dmg' --dir /tmp --clobber`
> 4. Mount it, copy **Dashi.app** into **/Applications**, then unmount:
>    `MNT="$(hdiutil attach -nobrowse -readonly /tmp/Dashi-0.1.0.dmg | awk -F'\t' 'END{print $NF}')"` →
>    `cp -R "$MNT/Dashi.app" /Applications/` → `hdiutil detach "$MNT"`
> 5. It's an **unsigned** build, so clear the Gatekeeper quarantine so it will launch:
>    `xattr -dr com.apple.quarantine /Applications/Dashi.app`
> 6. Launch it with `open -a Dashi` and tell me to look for the Dashi icon in the menu bar.
>
> Show me each command before you run it, and stop if any step fails.

To build from source instead, see [Development](#development) (`bash Scripts/make-dmg.sh`).

## Status

- **Shipped:** Claude 5-hour limit gauge (reads the local Claude Code OAuth token; personal use —
  see [Privacy](#privacy)).
- **Roadmap:** refresh/threshold alerts, and a multi-provider Admin-API usage/cost dashboard.

## Architecture

| Target       | Role                                                                          |
| ------------ | ----------------------------------------------------------------------------- |
| `DashiCore`  | All testable logic: config, secret-safe types, Keychain, redaction, providers |
| `Dashi`      | Thin SwiftUI `MenuBarExtra` app (no Dock icon) that renders `DashiCore` data  |

Usage sources are pluggable behind a `UsageProvider` protocol selected by a `ProviderMode` enum;
the **offline stub is the default**, and live providers lazy-load their network path only when
selected. See `Sources/DashiCore`.

## Privacy

Dashi talks **only to the AI providers' own APIs**, directly from your Mac — **no telemetry, no
analytics, no "phone home."** Your usage figures and credentials never leave your machine. The
Claude gauge reuses the OAuth token Claude Code already stores in your Keychain (read-only, never
copied or logged); note this is a **personal-use, ToS grey-area** feature. Full details, the threat
model, and how to revoke access are in **[SECURITY.md](SECURITY.md)**.

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

# package an unsigned (ad-hoc signed) .dmg for a GitHub release → dist/Dashi-<version>.dmg
# (needs create-dmg: brew install create-dmg)
bash Scripts/make-dmg.sh
```

The Xcode app target is generated from `project.yml` (XcodeGen); the `.xcodeproj` is gitignored. See
[RELEASING.md](RELEASING.md) for signing + notarization.

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
