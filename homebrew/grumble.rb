# Template for the Grumble cask. release.yml fills in the version and sha256
# from the built .dmg and pushes the result to fcjr/homebrew-fcjr.
cask "grumble" do
  version "VERSION_PLACEHOLDER"
  sha256 "SHA256_PLACEHOLDER"

  url "https://github.com/fcjr/grumble/releases/download/v#{version}/Grumble-#{version}.dmg"
  name "Grumble"
  desc "Local, on-device dictation"
  homepage "https://grumble.computer"

  depends_on macos: ">= :sonoma"

  auto_updates true

  app "Grumble.app"

  zap trash: [
    "~/Library/Application Support/FluidAudio",
    "~/Library/Caches/com.leftshift.grumble",
    "~/Library/HTTPStorages/com.leftshift.grumble",
    "~/Library/Preferences/com.leftshift.grumble.plist",
  ]
end
