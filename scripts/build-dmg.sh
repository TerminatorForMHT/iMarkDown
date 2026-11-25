#!/usr/bin/env bash
# 生成可直接分发的 DMG：Finder 图标布局 + 背景图 + 卷图标 + DMG 文件图标。
# 用法：./scripts/build-dmg.sh [debug|release]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${1:-release}"
APP_NAME="iMarkDown"
APP="$ROOT/dist/$APP_NAME.app"
STAGING="$ROOT/dist/dmg-staging"
RW_DMG="$ROOT/dist/$APP_NAME-rw.dmg"
ICON="$ROOT/Support/AppIcon.icns"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Support/Info.plist" 2>/dev/null || echo "0.0.0")"
VOL_NAME="$APP_NAME $VERSION"
FINAL_DMG="$ROOT/dist/$APP_NAME-$VERSION-macos.dmg"

"$ROOT/scripts/build-app.sh" "$CONFIG"

rm -rf "$STAGING"
rm -f "$RW_DMG" "$FINAL_DMG"
mkdir -p "$STAGING/.background"
ditto "$APP" "$STAGING/$APP_NAME.app"
ln -s /Applications "$STAGING/Applications"
cp "$ICON" "$STAGING/.VolumeIcon.icns"
swift "$ROOT/scripts/make-dmg-background.swift" "$STAGING/.background/background.png"

echo "==> 创建可写 DMG"
hdiutil create \
  -srcfolder "$STAGING" \
  -volname "$VOL_NAME" \
  -fs HFS+ \
  -format UDRW \
  -ov "$RW_DMG" >/dev/null

ATTACH_INFO="$(hdiutil attach -readwrite -noverify -noautoopen "$RW_DMG")"
DEVICE="$(printf '%s\n' "$ATTACH_INFO" | awk -F '\t' '/Apple_HFS/{print $1; exit}')"
MOUNT_DIR="$(printf '%s\n' "$ATTACH_INFO" | awk -F '\t' '/Apple_HFS/{print $3; exit}')"
if [ -z "$DEVICE" ] || [ -z "$MOUNT_DIR" ]; then
  echo "!! 无法挂载临时 DMG" >&2
  exit 1
fi

cleanup() {
  diskutil eject "$MOUNT_DIR" >/dev/null 2>&1 || hdiutil detach "$MOUNT_DIR" -force >/dev/null 2>&1 || true
}
trap cleanup EXIT

# 挂载后写入卷图标：-srcfolder 偶尔会漏掉根目录的隐藏文件，这里再兜底复制一次。
cp "$ICON" "$MOUNT_DIR/.VolumeIcon.icns" || echo "!! 写入 .VolumeIcon.icns 失败" >&2

echo "==> 设置 Finder 窗口布局"
if ! osascript <<APPLESCRIPT
tell application "Finder"
  tell disk "$VOL_NAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set pathbar visible of container window to false
    set the bounds of container window to {120, 120, 780, 540}
    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 128
    set text size of viewOptions to 13
    set background picture of viewOptions to file ".background:background.png"
    set position of item "$APP_NAME.app" of container window to {165, 204}
    set position of item "Applications" of container window to {495, 204}
    update without registering applications
    delay 2
    close
  end tell
end tell
APPLESCRIPT
then
  echo "!! Finder 布局设置失败（可能是自动化权限），DMG 仍会生成但不含自定义窗口" >&2
fi

# Finder 布局写完后再次确认卷图标文件确实在盘内，并用 NSWorkspace 给卷根节点
# 打上自定义图标标记（SetFile -a C 在当前 Command Line Tools 下不生效）。
if [ ! -f "$MOUNT_DIR/.VolumeIcon.icns" ]; then
  cp "$ICON" "$MOUNT_DIR/.VolumeIcon.icns" || true
fi
swift "$ROOT/scripts/set-file-icon.swift" "$ROOT/Support/AppIcon.png" "$MOUNT_DIR" \
  || echo "!! 卷图标标记失败，DMG 仍可正常使用" >&2
sync

echo "==> 压缩为只读 DMG"
# Finder 关闭窗口后仍需等待 .DS_Store 落盘，再整体卸载；优先用 diskutil，
# 它比 hdiutil detach 更可靠（后者在 macOS 27 上已标记废弃）。
sync
if [ -d "$MOUNT_DIR" ]; then
  diskutil eject "$MOUNT_DIR" >/dev/null || hdiutil detach "$DEVICE" -force >/dev/null
fi
if [ -d "$MOUNT_DIR" ]; then
  echo "!! 临时卷未能卸载，DMG 未生成：$MOUNT_DIR" >&2
  exit 1
fi
hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$FINAL_DMG" >/dev/null
rm -f "$RW_DMG"

# 给 DMG 文件本身挂图标，桌面 / Finder 中显示应用图标。
swift "$ROOT/scripts/set-file-icon.swift" "$ROOT/Support/AppIcon.png" "$FINAL_DMG"

rm -rf "$STAGING"

echo "==> 完成：$FINAL_DMG"
