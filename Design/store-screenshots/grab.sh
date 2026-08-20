#!/bin/sh
# Captures the Grumble windows that are currently open into captures/.
# Run this from a shell that has Screen Recording permission.
set -e
cd "$(dirname "$0")/../.."
mkdir -p Design/store-screenshots/captures

capture() {
    id=$(swift scripts/window-ids.swift Grumble | awk -F'\t' -v size="$1" '$3 == size {print $1; exit}')
    if [ -z "$id" ]; then
        echo "no $1 window open, launch with: open -n build/Build/Products/Release/Grumble.app --args --setup --meetings" >&2
        return 1
    fi
    screencapture -x -o -l "$id" "Design/store-screenshots/captures/$2"
    echo "captured $2 from window $id"
}

capture 470x599 setup-window.png
capture 900x612 meetings-window.png
