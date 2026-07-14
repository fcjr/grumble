sign_identity := env_var_or_default("SIGN_IDENTITY", "Developer ID Application: Left Shift Logical, LLC (KNBPD99JQM)")
notary_profile := env_var_or_default("NOTARY_PROFILE", "notary")

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
        -derivedDataPath build -quiet build
    mkdir -p build/pkg/dmg
    cp -R build/Build/Products/Release/Grumble.app build/pkg/dmg/
    codesign --force --options runtime --timestamp \
        --sign "{{ sign_identity }}" build/pkg/dmg/Grumble.app
    codesign --verify --strict --deep build/pkg/dmg/Grumble.app
    ln -s /Applications build/pkg/dmg/Applications
    hdiutil create -volname Grumble -srcfolder build/pkg/dmg -ov -format UDZO \
        build/Grumble.dmg
    codesign --force --timestamp --sign "{{ sign_identity }}" build/Grumble.dmg
    @echo "Signed DMG at build/Grumble.dmg"

# Notarize and staple the DMG (once: xcrun notarytool store-credentials notary)
notarize: pkg
    xcrun notarytool submit build/Grumble.dmg \
        --keychain-profile "{{ notary_profile }}" --wait
    xcrun stapler staple build/Grumble.dmg

# Remove generated project and build artifacts
clean:
    rm -rf Grumble.xcodeproj build DerivedData
