# Dashi

A small macOS **menu bar** dashboard for AI token usage. Connect your provider accounts
(Anthropic, OpenAI) and click the Dashi icon in the menu bar to see today's usage at a glance.

> macOS only for now. Native Swift + SwiftUI (`MenuBarExtra`).

## Status

Secure baseline + first usage slice. The offline stub runs with **no network, no credentials, and
no spend**; live providers are opt-in.

## Architecture

| Target       | Role                                                                          |
| ------------ | ----------------------------------------------------------------------------- |
| `DashiCore`  | All testable logic: config, secret-safe types, Keychain, redaction, providers |
| `Dashi`      | Thin SwiftUI `MenuBarExtra` app (no Dock icon) that renders `DashiCore` data  |

Usage sources are pluggable behind a `UsageProvider` protocol selected by a `ProviderMode` enum;
the **offline stub is the default**, and live providers lazy-load their network path only when
selected. See `Sources/DashiCore`.

## Security

- **Secrets never enter git.** API keys live in the **macOS Keychain** (`KeychainStore`), never in
  a file. `.env` holds non-secret config only.
- Defense-in-depth: a non-printing `Secret` wrapper, a secret-redacting log filter (`Redactor`),
  `gitleaks` in pre-commit **and** CI, and an `osv-scanner` dependency scan.
- CI is least-privilege (`contents: read`), all actions are SHA-pinned, and runs on PRs + a weekly
  schedule.

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
