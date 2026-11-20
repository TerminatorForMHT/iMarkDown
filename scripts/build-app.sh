#!/usr/bin/env bash
# 不依赖 Xcode 工程：SwiftPM 编译 + 手工组装 .app bundle + ad-hoc 签名。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${1:-release}"
APP_NAME="iMarkDown"
APP="$ROOT/dist/$APP_NAME.app"

cd "$ROOT"

if [ ! -f "Sources/iMarkDown/Resources/Web/vendor/codemirror/codemirror.min.js" ]; then
  echo "==> 首次构建，拉取 Web 依赖"
  "$ROOT/scripts/fetch-vendor.sh"
fi

echo "==> 编译 ($CONFIG)"
swift build -c "$CONFIG"

BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
BIN="$BIN_DIR/$APP_NAME"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
cp "$ROOT/Support/Info.plist" "$APP/Contents/Info.plist"

RES_BUNDLE="$BIN_DIR/${APP_NAME}_${APP_NAME}.bundle"
if [ -d "$RES_BUNDLE" ]; then
  cp -R "$RES_BUNDLE" "$APP/Contents/Resources/"
else
  echo "!! 找不到资源 bundle：$RES_BUNDLE" >&2
  exit 1
fi

if [ -f "$ROOT/Support/AppIcon.icns" ]; then
  cp "$ROOT/Support/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist" 2>/dev/null || true
fi

echo "==> Ad-hoc 签名"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

echo "==> 完成：$APP"
