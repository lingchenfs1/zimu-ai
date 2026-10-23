#!/bin/bash
# 把构建好的 ZimuAI.app 打包成 DMG。
# 用法：scripts/package_dmg.sh [ZimuAI.app 路径]
#
# 签名方式（按优先级）：
#   DEVELOPER_ID_APPLICATION  Developer ID 签名，例如 "Developer ID Application: Your Name (TEAMID)"；
#                             配合 NOTARY_APPLE_ID / NOTARY_PASSWORD / NOTARY_TEAM_ID 公证
#   CODESIGN_IDENTITY         自签名代码签名证书的 SHA-1（决策 D22），可选 CODESIGN_KEYCHAIN 指定钥匙串
#   都没有                    本地（ad-hoc）签名
# 输出 dist/ZimuAI-<版本>.dmg（手动安装）和 dist/ZimuAI-<版本>.zip（软件内更新）
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
ZIP_PATH="$DIST/ZimuAI-$VERSION.zip"
mkdir -p "$DIST"

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
cp -R "$APP_PATH" "$STAGING/ZimuAI.app"
APP="$STAGING/ZimuAI.app"

# 包内不应有需要单独签名的嵌套代码（WhisperKit、ZimuCore 都是静态链接）；以后加了要改成由内向外逐个签名
NESTED="$(find "$APP/Contents" \( -name '*.framework' -o -name '*.dylib' -o -name '*.xpc' -o -name '*.appex' \) -print)"
if [ -n "$NESTED" ]; then
  echo "包内有嵌套代码，需要逐个签名：" >&2
  echo "$NESTED" >&2
  exit 1
fi

# 签名（不使用 --deep：没有嵌套代码，且 --deep 不推荐用于签名）
if [ -n "${DEVELOPER_ID_APPLICATION:-}" ]; then
  echo "==> 使用 Developer ID 签名：$DEVELOPER_ID_APPLICATION"
  codesign --force --options runtime --timestamp \
    --entitlements "$ENTITLEMENTS" --sign "$DEVELOPER_ID_APPLICATION" "$APP"
elif [ -n "${CODESIGN_IDENTITY:-}" ]; then
  echo "==> 使用自签名证书签名：$CODESIGN_IDENTITY"
  codesign --force --options runtime --timestamp=none \
    ${CODESIGN_KEYCHAIN:+--keychain "$CODESIGN_KEYCHAIN"} \
    --entitlements "$ENTITLEMENTS" --sign "$CODESIGN_IDENTITY" "$APP"
else
  echo "==> 未配置签名证书，使用本地（ad-hoc）签名"
  codesign --force --options runtime \
    --entitlements "$ENTITLEMENTS" --sign - "$APP"
fi
codesign --verify --deep --strict --verbose=2 "$APP"
echo "==> 指定要求（designated requirement）："
codesign -d -r- "$APP" 2>&1 | tee "$STAGING/requirement.txt"
if [ -n "${CODESIGN_IDENTITY:-}" ] && [ -z "${DEVELOPER_ID_APPLICATION:-}" ]; then
  if ! grep -qi "$CODESIGN_IDENTITY" "$STAGING/requirement.txt"; then
    echo "指定要求里没有证书 $CODESIGN_IDENTITY，签名身份不固定" >&2
    exit 1
  fi
fi
rm -f "$STAGING/requirement.txt"

# 软件内更新用的 zip
rm -f "$ZIP_PATH"
ditto -c -k --keepParent "$APP" "$ZIP_PATH"

# DMG 内容：App + 应用程序文件夹快捷方式 + 安装说明
ln -s /Applications "$STAGING/Applications"
cat > "$STAGING/安装说明.txt" <<'TXT'
字幕AI 安装说明

1. 把「ZimuAI」拖到「Applications（应用程序）」文件夹。
2. 第一次打开时如果提示“无法验证开发者”（未公证的版本）：
   先关闭提示，打开 系统设置 › 隐私与安全性，在页面下方点「仍要打开」；
   或者在终端运行：xattr -dr com.apple.quarantine /Applications/ZimuAI.app
3. 以后的新版本可以在软件内更新：菜单栏面板会提示，也可以在 设置 › 更新与关于 中检查。
4. 启动后点击菜单栏的字幕图标，选择「开始字幕」。
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

echo "==> 完成："
shasum -a 256 "$DMG_PATH" "$ZIP_PATH"
