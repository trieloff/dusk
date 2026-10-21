#!/bin/bash
# Builds Dusk.app and installs it into ~/Applications, restarting it if it runs.
set -euo pipefail
cd "$(dirname "$0")"
xcodegen generate --quiet
xcodebuild -project Dusk.xcodeproj -scheme Dusk -configuration Release \
    -derivedDataPath build build -quiet
# Ask the running copy to quit like any app would (it is an app, so pkill is
# both rude and, under ai-aligned-pkill, refused for anything in ~/Applications).
if pgrep -x Dusk >/dev/null; then
    osascript -e 'tell application id "com.trieloff.dusk" to quit' 2>/dev/null || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x Dusk >/dev/null || break; sleep 0.5; done
    pgrep -x Dusk >/dev/null && { echo "Dusk did not quit; quit it from its menu and re-run" >&2; exit 1; }
fi
mkdir -p ~/Applications
rm -rf ~/Applications/Dusk.app
cp -R build/Build/Products/Release/Dusk.app ~/Applications/
open ~/Applications/Dusk.app
echo "installed ~/Applications/Dusk.app"
