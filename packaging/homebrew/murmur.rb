# Template for a Homebrew cask. Copy it into a tap repository (for example vinoth12940/homebrew-murmur,
# under Casks/murmur.rb) and update `version` and `sha256` after each release; see docs/RELEASING.md.
cask "murmur" do
  version "1.0.0"
  sha256 "REPLACE_WITH_THE_SHA256_FROM_Murmur-VERSION.dmg.sha256"

  url "https://github.com/vinoth12940/Murmur/releases/download/v#{version}/Murmur-#{version}.dmg"
  name "Murmur"
  desc "On-device dictation for the menu bar"
  homepage "https://github.com/vinoth12940/Murmur"

  depends_on arch: :arm64
  depends_on macos: ">= :tahoe"

  app "Murmur.app"

  zap trash: [
    "~/Library/Application Support/Murmur",
    "~/Library/Logs/Murmur.log",
    "~/Library/Logs/Murmur.log.1",
    "~/Library/Preferences/com.vinoth.murmur.plist",
  ]
end
