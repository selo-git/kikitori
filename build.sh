#!/bin/bash
# 使い方: ./build.sh          → build/Kikitori.app を作成
#         ./build.sh install  → ~/Applications にインストールして起動
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP=build/Kikitori.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Kikitori "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
codesign --force --sign - "$APP"
echo "built: $APP"

if [[ "${1:-}" == "install" ]]; then
    pkill -x Kikitori || true
    mkdir -p ~/Applications
    rm -rf ~/Applications/Kikitori.app
    cp -R "$APP" ~/Applications/
    open ~/Applications/Kikitori.app
    echo "installed: ~/Applications/Kikitori.app"
fi
