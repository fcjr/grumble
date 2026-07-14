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

# Remove generated project and build artifacts
clean:
    rm -rf Grumble.xcodeproj build DerivedData
