# Dashi

A small macOS **menu bar** app that shows your Claude subscription's **5-hour usage limit** at a
glance — click the menu bar icon to see how much of the rolling window you've used and when it
resets, without opening Claude. A multi-provider usage/cost dashboard (Anthropic, OpenAI) is on the
roadmap.

> macOS only for now. Native Swift + SwiftUI (`MenuBarExtra`).

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

## Development

Requires macOS with **Xcode** installed (the Command Line Tools alone lack XCTest).

```sh
# one-time
pre-commit install

# the full local gate (format-lint + build + test) — mirrors CI
bash Scripts/check.sh

# run the app
swift run Dashi
```

### Connecting a provider

Live per-day usage requires **admin/org-scoped** keys (Anthropic Usage & Cost Admin API; OpenAI
organization usage/costs endpoints) — ordinary API keys cannot read usage. Keys are stored in the
Keychain and read only at the point of use.

## Contributing

Every change ships as a small, tested, green slice via a feature branch and PR (see
`Scripts/check.sh` and the CI workflow). `main` is always releasable.

## License

MIT — see [LICENSE](LICENSE).
