#!/bin/bash
# Rebuilds OmniHub's character media from this project and copies it to
# Resources/character/ (committed; the app bundle takes it from there):
#
#   BootAnimation.mp4  the 7 s start-up film (HyperFrames render)
#   Background.jpg     illustration behind the dock card and settings
#   Avatar.png         head-and-shoulders, the dock ball's default icon
#   AppIcon.png        app icon built from the avatar
#
# Lan and her bird are drawn once, in character/lan.svg and character/bird.svg;
# assemble.py copies the drawings into the film and the stills.
# Needs Node (npx) and ffmpeg for the film render, and Google Chrome.
set -euo pipefail
cd "$(dirname "$0")"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
OUT=../../Resources/character
mkdir -p out "$OUT"

python3 assemble.py
npx --yes hyperframes@0.9.46 check
npx --yes hyperframes@0.9.46 render -o out/BootAnimation.mp4 -q delivery

"$CHROME" --headless=new --disable-gpu --hide-scrollbars --window-size=1280,720 \
  --screenshot="$PWD/out/background.png" "file://$PWD/stills/background.html" 2>/dev/null
"$CHROME" --headless=new --disable-gpu --hide-scrollbars --window-size=512,512 \
  --screenshot="$PWD/out/avatar.png" "file://$PWD/stills/avatar.html" 2>/dev/null

cp out/BootAnimation.mp4 "$OUT/BootAnimation.mp4"
sips -s format jpeg -s formatOptions 90 out/background.png --out "$OUT/Background.jpg" >/dev/null
cp out/avatar.png "$OUT/Avatar.png"
swift ../make-icon.swift "$OUT/Avatar.png" "$OUT/AppIcon.png"
ls -la "$OUT"
