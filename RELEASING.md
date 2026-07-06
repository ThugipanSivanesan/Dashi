# Releasing Dashi

Dashi handles access to your AI accounts, so how a build is signed matters. There are two tracks:

- **Option A — Unsigned community build (no Apple Developer account).** Free and immediate: build,
  ad-hoc sign, package a `.dmg`, publish on GitHub. Users approve it once through Gatekeeper. Good
  for getting Dashi into people's hands today. See **[Option A](#option-a--unsigned-community-build-no-apple-developer-account)**.
- **Option B — Signed + notarized (Developer ID).** Requires a paid Apple Developer membership but
  removes Gatekeeper friction and gives the strongest Keychain guarantees (stable app identity, no
  repeated access prompts). This is the recommended long-term route — see
  **[Option B](#option-b--signed--notarized-developer-id)** and the [Prerequisites](#prerequisites)
  below.

An unsigned app triggers Gatekeeper warnings and weakens the Keychain guarantees described in
[SECURITY.md](SECURITY.md); ad-hoc signing (Option A) recovers a stable identity but is still **not**
notarized.

---

## Option A — Unsigned community build (no Apple Developer account)

One command builds the app (unsigned), ad-hoc signs it, and packages a checksummed `.dmg`:

```sh
brew install xcodegen create-dmg   # one-time
bash Scripts/make-dmg.sh           # → dist/Dashi-<version>.dmg (+ .sha256)
```

`Scripts/make-dmg.sh` runs `Scripts/build-app.sh` if needed, ad-hoc signs `Dashi.app`
(`codesign --sign -` — free, no account; set `DASHI_ADHOC=0` to skip), then uses
[`create-dmg`](https://github.com/create-dmg/create-dmg) to produce a compressed `.dmg` whose
mounted window shows the familiar drag-**Dashi**-onto-**Applications** layout, plus a SHA-256
sidecar.

### What your users will see

The build is **not notarized**, so macOS quarantines it on download and Gatekeeper blocks the first
launch. To run it, users either:

- open **System Settings → Privacy & Security**, scroll down, and click **"Open Anyway"** (on
  macOS 15 Sequoia the old Control-click → Open shortcut no longer bypasses Gatekeeper), or
- clear the quarantine flag manually: `xattr -dr com.apple.quarantine /Applications/Dashi.app`.

Document this in the release notes so people aren't surprised.

### Publish on GitHub

```sh
gh release create v<version> \
  dist/Dashi-<version>.dmg dist/Dashi-<version>.dmg.sha256 \
  --title "Dashi v<version>" \
  --notes "Unsigned community build (not notarized). First launch: System Settings → Privacy & Security → Open Anyway. Verify the download against the .sha256."
```

Tag and publish under your own identity (no AI attribution), per the repo convention.

### Trust

This is an unsigned + ad-hoc build, so trust comes from transparency, not Apple: publish the
**SHA-256** alongside the `.dmg` (the script writes it) and point users at building from source —
Dashi is open, so anyone can reproduce the bundle and compare. For a binary that touches credentials,
graduating to Option B is the real fix once you have a membership.

---

## Option B — Signed + notarized (Developer ID)

The recommended trusted release. This document's checklist below covers it end-to-end.

## Prerequisites

- An **Apple Developer Program** membership.
- A **Developer ID Application** signing certificate in your login Keychain
  (Xcode → Settings → Accounts → Manage Certificates, or the Developer portal).
- A **notarytool keychain profile** holding an app-specific password:
  ```sh
  xcrun notarytool store-credentials AC_PASSWORD \
    --apple-id "you@example.com" --team-id "TEAMID" --password "app-specific-password"
  ```

## 1. Build the app bundle

A SwiftPM executable is a bare binary, not a `.app`. The distributable bundle is produced by the
Xcode app target, which is generated from [`project.yml`](project.yml) by XcodeGen (the generated
`Dashi.xcodeproj` is gitignored) and depends on `DashiCore`. One command does both:

```sh
brew install xcodegen          # one-time
bash Scripts/build-app.sh      # → .build/xcode/Build/Products/Release/Dashi.app
```

`Dashi.app` is menu-bar-only (`LSUIElement`), bundle id `com.dashi.app`. `Scripts/build-app.sh`
builds unsigned by default; set `DASHI_SIGN=1` (with a `DEVELOPMENT_TEAM`) once you're ready to sign,
then continue below. (`swift run Dashi` remains the quick path for development.)

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

- Package the notarized bundle. Pass `DASHI_ADHOC=0` so the packaging scripts keep your Developer ID
  signature instead of re-signing ad-hoc:
  ```sh
  DASHI_ADHOC=0 bash Scripts/make-dmg.sh    # → dist/Dashi-<version>.dmg (+ .sha256)
  DASHI_ADHOC=0 bash Scripts/make-zip.sh    # → dist/Dashi-<version>.zip (+ .sha256)  ← Sparkle feed
  ```
- Both scripts write **SHA-256 sidecars** so users (and the Homebrew cask) can verify what they
  downloaded. Because Dashi is open source, security-conscious users can also build from source and
  compare.
- Attach the `.dmg`, `.zip`, and both `.sha256` files to the GitHub Release.

See [Auto-updates](#auto-updates-sparkle) below for the Sparkle appcast, and
[Homebrew](#homebrew-cask) / [Automated releases](#automated-releases-github-actions) for the rest.

## Trust summary

Signed + notarized + checksummed releases, a minimal entitlement set, and a reproducible
open-source build are what let the community trust a binary that touches their credentials. See
[SECURITY.md](SECURITY.md) for the full security and privacy model.

---

## Auto-updates (Sparkle)

The app target links [Sparkle](https://sparkle-project.org) for in-app updates. It's wired but
**inert until you configure an update-signing key** — `App/Info.plist` ships with an empty
`SUPublicEDKey`, so the app never checks for updates and "Check for Updates…" stays disabled. This is
deliberate: an unconfigured ad-hoc build can't serve or verify updates anyway.

One-time setup (requires a signed + notarized release flow, so pair it with Option B):

1. **Generate the EdDSA key pair** (the private key is stored in your login Keychain):
   ```sh
   ./Scripts/generate-appcast.sh   # fails first run if tools missing — run `swift build` once to fetch Sparkle
   # Generate keys with Sparkle's tool (also inside the fetched artifact):
   $(find .build -path '*/Sparkle/bin/generate_keys' | head -1)
   ```
   It prints a **public key** — paste it into `SUPublicEDKey` in `App/Info.plist`.
2. Confirm `SUFeedURL` in `App/Info.plist` points where you'll host the appcast (default:
   `https://raw.githubusercontent.com/ThugipanSivanesan/Dashi/main/appcast.xml`).
3. On each release, after signing + notarizing + zipping (steps above), **generate the appcast**:
   ```sh
   DOWNLOAD_URL_PREFIX="https://github.com/ThugipanSivanesan/Dashi/releases/download/v<version>/" \
     bash Scripts/generate-appcast.sh
   ```
   This EdDSA-signs each update and writes `appcast.xml`. Commit it (so the raw `SUFeedURL` serves the
   current feed) and attach the signed `.zip` to the release.
4. Flip `SUEnableAutomaticChecks` to `true` in `App/Info.plist` once you're happy for the app to
   check automatically.

> Note: `raw.githubusercontent.com` caches for a few minutes; for faster propagation host the appcast
> on GitHub Pages instead and update `SUFeedURL` to match.

## Homebrew cask

[`Casks/dashi.rb`](Casks/dashi.rb) is a cask template. To offer `brew install --cask dashi`:

1. Create a tap repo (e.g. `ThugipanSivanesan/homebrew-tap`).
2. On each release, update `version` + `sha256` (`shasum -a 256 dist/Dashi-<version>.zip`) in the
   cask and copy it into the tap's `Casks/` directory.
3. Users then run `brew tap ThugipanSivanesan/tap && brew install --cask dashi`.

The cask installs the `.zip` build and sets `auto_updates true` so Homebrew defers to Sparkle.

## Automated releases (GitHub Actions)

[`.github/workflows/release.yml`](.github/workflows/release.yml) runs on a `v*` tag push (or manual
dispatch). With no secrets set it builds the **ad-hoc** `.dmg` + `.zip` and publishes a GitHub
Release. Add these repo secrets to unlock the signed + notarized path (sign → notarize → staple →
appcast): `DEVELOPER_ID`, `MACOS_CERT_P12_BASE64`, `MACOS_CERT_PASSWORD`, `NOTARY_APPLE_ID`,
`NOTARY_TEAM_ID`, `NOTARY_PASSWORD`.

> Heads-up: GitHub Actions must be enabled/funded for this to run — see the repo's CI status.
