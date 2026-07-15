# Mac App Store screenshots

Marketing screenshots for the App Store listing, rendered from these HTML
scenes at exactly 2880x1800 with headless Chrome:

```sh
chrome="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
for n in 1 2 3; do
  "$chrome" --headless=new --disable-gpu --window-size=1440,900 \
    --force-device-scale-factor=2 --hide-scrollbars \
    --virtual-time-budget=8000 --screenshot="shot$n.png" "shot$n.html"
done
```

Colors and type match apps/web (styles.css); the pill mirrors the real
OverlayController.
