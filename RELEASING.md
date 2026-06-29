# Releasing Dashi

Dashi handles access to your AI accounts, so distributed builds must be **code-signed and
notarized**. An unsigned app triggers Gatekeeper warnings, *and* weakens the Keychain guarantees
(repeated access prompts, no stable app identity), which undermines the protections described in
[SECURITY.md](SECURITY.md). This document is the checklist for cutting a trusted release.

## Prerequisites

- An **Apple Developer Program** membership.
- A **Developer ID Application** signing certificate in your login Keychain
  (Xcode → Settings → Accounts → Manage Certificates, or the Developer portal).
- A **notarytool keychain profile** holding an app-specific password:
  ```sh
  xcrun notarytool store-credentials AC_PASSWORD \
    --apple-id "you@example.com" --team-id "TEAMID" --password "app-specific-password"
  ```

## 1. Build a release binary

```sh
swift build -c release        # → .build/release/Dashi
```

> **Note — bundling.** A SwiftPM executable is a bare binary, not a `.app`. For distribution you
> need a real app bundle. The robust path is to add an **Xcode app target** that depends on
> `DashiCore` and produces `Dashi.app` (with `LSUIElement = true` so it stays menu-bar-only). The
> steps below assume you have a `Dashi.app` — either from that Xcode target or assembled manually
> (`Dashi.app/Contents/{MacOS/Dashi, Info.plist}`).

## 2. Sign with Hardened Runtime

Notarization requires the **hardened runtime** (`--options runtime`):

```sh
codesign --force --deep --options runtime --timestamp \
  --sign "Developer ID Application: Your Name (TEAMID)" \
  Dashi.app
codesign --verify --strict --verbose=2 Dashi.app   # verify
```

Keep entitlements minimal. Dashi only needs outbound network access; if you enable the App Sandbox,
add `com.apple.security.network.client`. Do **not** add capabilities you don't use.

## 3. Notarize and staple

```sh
ditto -c -k --keepParent Dashi.app Dashi.zip
xcrun notarytool submit Dashi.zip --keychain-profile AC_PASSWORD --wait
xcrun stapler staple Dashi.app        # attach the ticket for offline Gatekeeper checks
```

## 4. Verify Gatekeeper acceptance

```sh
spctl --assess --type execute --verbose=4 Dashi.app   # expect: accepted, source=Notarized Developer ID
codesign -dvvv Dashi.app                               # confirm identifier, TeamID, hardened runtime
```

## 5. Package and publish

- Wrap `Dashi.app` in a `.dmg` or `.zip` for the GitHub Release.
- Publish **SHA-256 checksums** alongside the artifact so users can verify what they downloaded:
  ```sh
  shasum -a 256 Dashi.dmg > Dashi.dmg.sha256
  ```
- Because Dashi is open source, security-conscious users can also build from source and compare.

## Trust summary

Signed + notarized + checksummed releases, a minimal entitlement set, and a reproducible
open-source build are what let the community trust a binary that touches their credentials. See
[SECURITY.md](SECURITY.md) for the full security and privacy model.
