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
brew install xcodegen          # one-time
bash Scripts/make-dmg.sh       # → dist/Dashi-<version>.dmg (+ .sha256)
```

`Scripts/make-dmg.sh` runs `Scripts/build-app.sh` if needed, ad-hoc signs `Dashi.app`
(`codesign --sign -` — free, no account; set `DASHI_ADHOC=0` to skip), then produces a compressed
`.dmg` with an `/Applications` drag-to-install symlink and a SHA-256 sidecar.

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
