#!/bin/bash
# Builds Dusk.app and installs it into ~/Applications, restarting it if it runs.
set -euo pipefail
cd "$(dirname "$0")"
xcodegen generate --quiet
xcodebuild -project Dusk.xcodeproj -scheme Dusk -configuration Release \
    -derivedDataPath build build -quiet
pkill -x Dusk 2>/dev/null && sleep 1 || true
mkdir -p ~/Applications
rm -rf ~/Applications/Dusk.app
cp -R build/Build/Products/Release/Dusk.app ~/Applications/
open ~/Applications/Dusk.app
echo "installed ~/Applications/Dusk.app"
