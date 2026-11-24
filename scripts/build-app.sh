#!/usr/bin/env bash
# 不依赖 Xcode 工程：SwiftPM 编译 + 手工组装 .app bundle + ad-hoc 签名。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${1:-release}"
PRODUCT_NAME="iMarkDown"
APP_NAME="$PRODUCT_NAME"
APP="$ROOT/dist/$APP_NAME.app"
UI_CHECK="${IMARKDOWN_UI_CHECK:-0}"
if [ "$UI_CHECK" = "1" ]; then
  APP_NAME="iMarkDown-UI-Check"
  APP="$ROOT/.build/ui-validation/$APP_NAME.app"
fi

cd "$ROOT"

if [ ! -f "Sources/iMarkDown/Resources/Web/vendor/codemirror/codemirror.min.js" ]; then
  echo "==> 首次构建，拉取 Web 依赖"
  "$ROOT/scripts/fetch-vendor.sh"
fi

BUILD_ARGS=(-c "$CONFIG")
if [ "$UI_CHECK" = "1" ]; then
  BUILD_ARGS+=(--scratch-path "$ROOT/.build/ui-validation/build" -Xswiftc -DIMARKDOWN_UI_CHECK)
fi
SDK="${IMARKDOWN_SDK:-}"
if [ -z "$SDK" ]; then
  for candidate in /Library/Developer/CommandLineTools/SDKs/MacOSX26*.sdk; do
    if [ -d "$candidate" ]; then SDK="$candidate"; break; fi
  done
fi
if [ -n "$SDK" ]; then
  if [ ! -d "$SDK" ]; then
    echo "!! SDK 不存在：$SDK" >&2
    exit 1
  fi
  BUILD_ARGS+=(--sdk "$SDK")
fi

echo "==> 编译 ($CONFIG)"
swift build "${BUILD_ARGS[@]}"

BIN_DIR="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"
BIN="$BIN_DIR/$PRODUCT_NAME"

if [ -d "$APP" ]; then
  mv "$APP" "$(dirname "$APP")/$APP_NAME.previous.$(date +%s).app"
fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/$PRODUCT_NAME"
cp "$ROOT/Support/Info.plist" "$APP/Contents/Info.plist"
if [ "$UI_CHECK" = "1" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.jasperwang.imarkdown.ui-check" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleName iMarkDown-UI-Check" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName iMarkDown UI 验收" "$APP/Contents/Info.plist"
fi

RES_BUNDLE="$BIN_DIR/${PRODUCT_NAME}_${PRODUCT_NAME}.bundle"
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
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"

echo "==> 完成：$APP"
