#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
swift build -c release
APP="$ROOT/dist/LanShare.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/LanShare "$APP/Contents/MacOS/LanShare"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/LanShare.icns "$APP/Contents/Resources/LanShare.icns"
echo "Built $APP"
