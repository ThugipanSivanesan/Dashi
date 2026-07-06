# Security & Privacy

Dashi handles access to your AI accounts, so security and privacy are first-class concerns. This
document describes what Dashi does with your data and how to report problems. Dashi is pre-1.0;
security fixes target the latest commit on `main`.

## Reporting a vulnerability

Please report security issues **privately** via GitHub's *Report a vulnerability* (the repo's
**Security** tab → *Advisories*), not as a public issue. We'll acknowledge and work a fix before any
public disclosure.

## Privacy promise: your data stays on your Mac

- Dashi talks **only to the AI providers' own APIs**, directly from your machine
  (currently `https://api.anthropic.com` for Claude and `https://chatgpt.com` for Codex).
- **No telemetry, no analytics, no crash reporting, no "phone home."** Your usage figures and your
  credentials are never sent to the author or any third party.
- Usage data is rendered in the popup and held in memory only — Dashi does not write it to disk.

## How Dashi handles credentials

### Claude subscription gauge (personal / experimental)

- Reads the OAuth token that **Claude Code** already stores in your login Keychain (item
  `Claude Code-credentials`). macOS prompts you to grant Dashi access the first time.
- Used **read-only** to call the usage endpoint. Dashi **never stores its own copy, writes it to
  disk, or logs it** — the token is read transiently at the point of use.
- ⚠️ **Terms-of-Service note:** reusing a subscription token outside official Anthropic clients is a
  grey area and may violate Anthropic's Terms. This feature is for **personal use, at your own
  risk**, and is **not recommended for redistribution**. It can also break without notice if the
  endpoint changes.

### Codex subscription gauge (personal / experimental)

- Reads the OAuth token the **Codex CLI** stores in `~/.codex/auth.json` (or `$CODEX_HOME/auth.json`).
  This is a plain file that the Codex CLI itself writes; Dashi opens it **read-only**.
- Used **read-only** to call `chatgpt.com/backend-api/wham/usage`. Dashi **never stores its own copy,
  writes it to disk, or logs it** — the token is read transiently at the point of use.
- **Dashi never writes back to `auth.json`.** Codex uses rotating refresh tokens, so refreshing
  would mean rewriting the CLI's credentials and could invalidate your Codex CLI login. Dashi
  therefore does not refresh: if the stored token is rejected it asks you to re-authenticate (run
  `codex`) rather than touching the file.
- ⚠️ **Terms-of-Service note:** same grey area as the Claude gauge — reusing a subscription token
  outside official OpenAI clients may violate OpenAI's Terms. **Personal use, at your own risk.**

### Provider API keys (Admin usage/cost — planned)

- Stored **only in the macOS Keychain** (OS-encrypted at rest), never in a file, with
  `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` so secrets are not synced off the device.
- Read at the point of use; **Disconnect deletes them** from the Keychain.
- Prefer a **dedicated, revocable** key with the narrowest scope your provider offers — Admin keys
  are powerful, so limit the blast radius.

## Defense-in-depth

- Secrets are wrapped in a non-printing `Secret` type and every log line passes through a redacting
  filter (`Redactor`), so a key cannot land in logs by accident.
- `.env` is for **non-secret config only**; secrets never go in files. `.gitignore` excludes `.env`,
  `*.key`, `*.pem`, and `secrets/`.
- `gitleaks` runs in pre-commit **and** CI; `osv-scanner` + Dependabot watch dependencies; CI is
  least-privilege (`contents: read`) with SHA-pinned actions.

## Scope

**In scope:** credential storage and handling, log redaction, local-only data flow, and the network
endpoints Dashi calls.

**Out of scope:** the security of the provider APIs themselves, and the inherent ToS risk of the
personal Claude-gauge feature (documented above).

## Distributing a build

Distributed builds must be **code-signed (Developer ID) + notarized**, with minimal entitlements and
published checksums — unsigned apps weaken both Gatekeeper and the Keychain guarantees above. The
full checklist is in [RELEASING.md](RELEASING.md).

## Revoking access

- **Claude gauge:** log out of Claude Code (removes the shared token), or revoke the session/device
  from your Anthropic account.
- **Codex gauge:** log out of the Codex CLI (`codex logout`, which clears `~/.codex/auth.json`), or
  revoke the session from your OpenAI account.
- **API keys:** delete the key in the provider's console, then click **Disconnect** in Dashi to
  remove it from the Keychain.
