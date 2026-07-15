sign_identity := env_var_or_default("SIGN_IDENTITY", "Developer ID Application: Left Shift Logical, LLC (KNBPD99JQM)")
notary_profile := env_var_or_default("NOTARY_PROFILE", "notary")

# CI overrides these from the release tag; local builds use project.yml defaults.
app_version := env_var_or_default("APP_VERSION", "")
app_build := env_var_or_default("APP_BUILD", "")
version_flags := (if app_version != "" { "MARKETING_VERSION=" + app_version } else { "" }) + " " + (if app_build != "" { "CURRENT_PROJECT_VERSION=" + app_build } else { "" })

# Show available recipes
default:
    @just --list

# Generate the Xcode project
generate:
    xcodegen generate

# Build the app
build: generate
    xcodebuild -project Grumble.xcodeproj -scheme Grumble -quiet build

# Build and launch the app
run: build
    open "$(xcodebuild -project Grumble.xcodeproj -scheme Grumble \
        -showBuildSettings build 2>/dev/null \
        | awk '/ BUILT_PRODUCTS_DIR/ {print $3}')/Grumble.app"

# Generate and open in Xcode
open: generate
    xed Grumble.xcodeproj

# Build Release, sign with Developer ID, and package a DMG
pkg: generate
    rm -rf build/pkg
    xcodebuild -project Grumble.xcodeproj -scheme Grumble -configuration Release \
        -derivedDataPath build -quiet build {{ version_flags }}
    mkdir -p build/pkg/dmg
    cp -R build/Build/Products/Release/Grumble.app build/pkg/dmg/
    codesign --force --options runtime --timestamp \
        --sign "{{ sign_identity }}" build/pkg/dmg/Grumble.app
    codesign --verify --strict --deep build/pkg/dmg/Grumble.app
    rm -f build/Grumble.dmg
    create-dmg \
        --volname "Grumble" \
        --volicon Resources/AppIcon.icns \
        --background Design/dmg-background.tiff \
        --window-pos 200 150 \
        --window-size 620 420 \
        --icon-size 128 \
        --icon "Grumble.app" 160 205 \
        --hide-extension "Grumble.app" \
        --app-drop-link 460 205 \
        --no-internet-enable \
        build/Grumble.dmg build/pkg/dmg
    codesign --force --timestamp --sign "{{ sign_identity }}" build/Grumble.dmg
    @echo "Signed DMG at build/Grumble.dmg"

# Notarize and staple the DMG (once: xcrun notarytool store-credentials notary)
notarize: pkg
    xcrun notarytool submit build/Grumble.dmg \
        --keychain-profile "{{ notary_profile }}" --wait
    xcrun stapler staple build/Grumble.dmg

# Package a Sparkle update zip and regenerate the appcast served at
# grumble.computer/desktop/darwin/appcast.xml. Enclosures point at GitHub
# release assets; normally CI runs this on tag push (see release.yml).
appcast: pkg
    #!/usr/bin/env bash
    set -euo pipefail
    version=$(plutil -extract CFBundleShortVersionString raw \
        build/pkg/dmg/Grumble.app/Contents/Info.plist)
    mkdir -p build/updates apps/web/public/desktop/darwin
    ditto -c -k --keepParent build/pkg/dmg/Grumble.app \
        "build/updates/Grumble-$version.zip"
    sparkle_bin=build/SourcePackages/artifacts/sparkle/Sparkle/bin
    "$sparkle_bin/generate_appcast" build/updates \
        ${SPARKLE_PRIVATE_KEY_FILE:+--ed-key-file "$SPARKLE_PRIVATE_KEY_FILE"} \
        --download-url-prefix "https://github.com/fcjr/grumble/releases/download/v$version/"
    cp build/updates/appcast.xml apps/web/public/desktop/darwin/appcast.xml
    echo "Appcast at apps/web/public/desktop/darwin/appcast.xml"

# Remove generated project and build artifacts
clean:
    rm -rf Grumble.xcodeproj build DerivedData
