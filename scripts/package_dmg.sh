#!/bin/bash
# 把构建好的 ZimuAI.app 打包成 DMG。
# 用法：scripts/package_dmg.sh [ZimuAI.app 路径]
#
# 可选环境变量（有则使用 Developer ID 签名并公证，没有则使用本地签名）：
#   DEVELOPER_ID_APPLICATION  例如 "Developer ID Application: Your Name (TEAMID)"
#   NOTARY_APPLE_ID / NOTARY_PASSWORD / NOTARY_TEAM_ID  用于 notarytool 公证
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="${1:-$ROOT/build/DerivedData/Build/Products/Release/ZimuAI.app}"
ENTITLEMENTS="$ROOT/App/ZimuAI.entitlements"
DIST="$ROOT/dist"

if [ ! -d "$APP_PATH" ]; then
  echo "找不到 $APP_PATH，请先构建 Release 版本" >&2
  exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist")"
DMG_PATH="$DIST/ZimuAI-$VERSION.dmg"
mkdir -p "$DIST"

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
cp -R "$APP_PATH" "$STAGING/ZimuAI.app"
APP="$STAGING/ZimuAI.app"

# 签名
if [ -n "${DEVELOPER_ID_APPLICATION:-}" ]; then
  echo "==> 使用 Developer ID 签名：$DEVELOPER_ID_APPLICATION"
  codesign --force --deep --options runtime --timestamp \
    --entitlements "$ENTITLEMENTS" --sign "$DEVELOPER_ID_APPLICATION" "$APP"
else
  echo "==> 未配置 Developer ID，使用本地（ad-hoc）签名"
  codesign --force --deep --options runtime \
    --entitlements "$ENTITLEMENTS" --sign - "$APP"
fi
codesign --verify --deep --strict --verbose=2 "$APP"

# DMG 内容：App + 应用程序文件夹快捷方式 + 安装说明
ln -s /Applications "$STAGING/Applications"
cat > "$STAGING/安装说明.txt" <<'TXT'
字幕AI 安装说明

1. 把「ZimuAI」拖到「Applications（应用程序）」文件夹。
2. 如果打开时提示“无法验证开发者”（未公证的版本）：
   在「应用程序」中右键点击 ZimuAI → 打开 → 再次点击「打开」；
   或者在终端运行：xattr -dr com.apple.quarantine /Applications/ZimuAI.app
3. 启动后点击菜单栏的字幕图标，选择「开始字幕」。
   第一次开始时，系统会请求「录制系统音频」权限，请允许。

系统要求：macOS 26 (Tahoe) 及以上。
TXT

rm -f "$DMG_PATH"
hdiutil create -volname "字幕AI" -srcfolder "$STAGING" -ov -format UDZO "$DMG_PATH"

if [ -n "${DEVELOPER_ID_APPLICATION:-}" ]; then
  codesign --force --timestamp --sign "$DEVELOPER_ID_APPLICATION" "$DMG_PATH"
  if [ -n "${NOTARY_APPLE_ID:-}" ] && [ -n "${NOTARY_PASSWORD:-}" ] && [ -n "${NOTARY_TEAM_ID:-}" ]; then
    echo "==> 提交公证"
    xcrun notarytool submit "$DMG_PATH" \
      --apple-id "$NOTARY_APPLE_ID" --password "$NOTARY_PASSWORD" --team-id "$NOTARY_TEAM_ID" --wait
    xcrun stapler staple "$DMG_PATH"
  fi
fi

echo "==> 完成：$DMG_PATH"
