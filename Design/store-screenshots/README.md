# Mac App Store screenshots

App Review rejected the previous set under guideline 2.3.3: they were HTML
mockups of invented windows, not the app. Every screenshot here now starts as a
real capture of Grumble running.

## 1. Capture the app

Window captures come out at Retina scale with the shadow preserved. Find the
window id first, since `screencapture -w` needs a click:

```sh
swift scripts/window-ids.swift Grumble        # id, size, title per window
screencapture -x -o -l <id> captures/setup-window.png
```

Full-screen captures are the better choice when the shot needs both the target
app and Grumble's overlay, which are separate windows:

```sh
screencapture -x -t png captures/dictation-screen.png
```

To capture dictation without a second person at the keyboard: focus a text
field, press the hotkey, and let the built-in speakers feed the built-in mic.

```sh
say -r 160 "The meeting could have been an email. The email could have been a grumble."
```

`captures/` holds the raw source images. They are committed because they cannot
be regenerated deterministically.

## 2. Compose

`out/01-dictation.png` is the raw screen capture with the Dock trimmed off,
padded to 16:10 and scaled to 2880x1800. Nothing is overlaid on it, which is
the most direct answer to a 2.3.3 rejection.

Scenes in `scenes/` place a real capture on the brand background with a
headline, rendered at exactly 2880x1800:

`out/` is generated and gitignored, so create it first.

```sh
mkdir -p out
chrome="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
for f in scenes/*.html; do
  "$chrome" --headless=new --disable-gpu --window-size=1440,900 \
    --force-device-scale-factor=2 --hide-scrollbars \
    --virtual-time-budget=8000 \
    --screenshot="out/$(basename "${f%.html}").png" "$f"
done
```

Keep captures at 1:1 inside a scene. A window captured at 940x1196 is 470x598
CSS pixels at the 2x device scale factor, so it stays pixel sharp.

Colors and type match apps/web (styles.css).

## Rules to keep the next submission out of trouble

- No invented windows, no fake app chrome, no drawn re-creations of the
  overlay. Capture the real thing.
- Setup and permission windows read as setup screens rather than the app in
  use. Keep them in the minority of the set.
- The majority of shots must show a core feature actually working.

## Demo data for the Meetings shot

Real meetings are not fit for a public listing, so the Meetings window is shot
against a seeded meeting instead. The app UI in the capture is real; only the
content is invented.

```sh
db=~/Library/Application\ Support/Grumble/grumble.sqlite
cp "$db" /tmp/grumble.sqlite.backup                  # always back up first
sqlite3 "$db" < Design/store-screenshots/demo-meeting.sql

# playback needs tracks to exist; 252 s of silence is enough for the scrubber
dir=~/Library/Application\ Support/Grumble/Meetings/2026-08-18T14-00-00Z-demo
mkdir -p "$dir"   # write mic.caf and system.caf here, see git history for the snippet

open -n build/Build/Products/Release/Grumble.app --args --meetings
swift scripts/window-ids.swift Grumble               # find the 900x612 window
screencapture -x -o -l <id> captures/meetings-window.png

sqlite3 "$db" "DELETE FROM segments WHERE meetingId=9001;
               DELETE FROM speakers WHERE meetingId=9001;
               DELETE FROM meetings WHERE id=9001;"
rm -rf "$dir"
```

The `--meetings` launch flag exists for exactly this, alongside `--setup`.
