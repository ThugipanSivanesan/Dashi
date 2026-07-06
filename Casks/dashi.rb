# Homebrew cask for Dashi — a template for your tap (e.g. a `homebrew-tap` repo:
# `brew tap ThugipanSivanesan/tap && brew install --cask dashi`).
#
# Update `version` and `sha256` on each release (`shasum -a 256 dist/Dashi-<version>.zip`), then copy
# this file into your tap's `Casks/` directory. The cask installs the notarized (or ad-hoc) .zip
# produced by Scripts/make-zip.sh. See RELEASING.md.
cask "dashi" do
  version "0.2.0"
  sha256 "REPLACE_WITH_ZIP_SHA256" # shasum -a 256 dist/Dashi-#{version}.zip

  url "https://github.com/ThugipanSivanesan/Dashi/releases/download/v#{version}/Dashi-#{version}.zip"
  name "Dashi"
  desc "Menu-bar gauge for Claude and Codex subscription usage"
  homepage "https://github.com/ThugipanSivanesan/Dashi"

  # Sparkle powers in-app updates once configured; use auto_updates so Homebrew defers to it.
  auto_updates true
  depends_on macos: ">= :sonoma"

  app "Dashi.app"

  zap trash: [
    "~/Library/Preferences/com.dashi.app.plist",
  ]
end
