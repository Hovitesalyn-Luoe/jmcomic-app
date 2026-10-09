#!/bin/bash
# 构建 JMComic.app 并安装到 /Applications
#
# SwiftPM 只产出裸二进制，双击不了、Dock 图标是通用图标、也没法设权限描述。
# 这里补上 .app bundle 结构：Info.plist + 正确的目录布局 + ad-hoc 签名。
#
#   ./build-app.sh           构建到 jmcomic-swift/dist/JMComic.app
#   ./build-app.sh --install 构建并安装到 /Applications
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="JMComic"
BUNDLE_ID="local.jmcomic.reader"
VERSION="1.2.0"
# 本 fork 的发布标记：与 GitHub Release 的 tag 一致，"检查更新"拿它比对。
# 可用环境变量覆盖：RELEASE_TAG=v1.2.0-fix4 ./build-app.sh
RELEASE_TAG="${RELEASE_TAG:-v1.2.0-fix4}"
APP_DIR="dist/${APP_NAME}.app"

echo "==> 构建 release"
swift build -c release

# 二进制路径交给 SwiftPM 自己报（不同工具链/版本下 .build 布局不一样，
# 写死路径会在别的机器上直接失败）
BIN_PATH="$(swift build -c release --show-bin-path)/${APP_NAME}"
echo "==> 二进制：${BIN_PATH}"

echo "==> 自检"
"$BIN_PATH" --selfcheck

echo "==> 组装 ${APP_DIR}"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/${APP_NAME}"
# App 图标（与 AppIcon.icns 同目录，缺失则跳过，不阻塞构建）
# 中文界面：放一个真实的 zh-Hans.lproj，系统才会认为本 App"支持中文"，
# 进而把标准菜单栏（File/Edit/View/Window/Help 及其展开项）也按中文渲染
mkdir -p "$APP_DIR/Contents/Resources/zh-Hans.lproj"
: > "$APP_DIR/Contents/Resources/zh-Hans.lproj/Localizable.strings"

if [ -f "AppIcon.icns" ]; then
    cp "AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
fi

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>JMReleaseTag</key><string>${RELEASE_TAG}</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleExecutable</key><string>${APP_NAME}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <!-- 有窗口的普通 App，不是后台代理 -->
    <key>LSUIElement</key><false/>
    <key>NSHighResolutionCapable</key><true/>
    <!-- 图片走 HTTPS，无需 ATS 例外 -->
    <key>NSHumanReadableCopyright</key><string>Local build. Personal use.</string>
    <!-- 声明中文：系统据此把标准菜单栏（File/Edit/View/Window/Help）渲染为中文 -->
    <key>CFBundleDevelopmentRegion</key><string>zh-Hans</string>
    <key>CFBundleLocalizations</key>
    <array>
        <string>zh-Hans</string>
        <string>zh-Hant</string>
        <string>en</string>
    </array>
    <!-- 局域网 web 服务的本地网络权限说明（macOS 15+ 弹窗文案） -->
    <key>NSLocalNetworkUsageDescription</key><string>JMComic 需要在同一局域网内接受手机浏览器的访问，以便扫码阅读漫画。</string>
</dict>
</plist>
PLIST

# ad-hoc 签名：没有开发者账号也能签。这样 Gatekeeper 不会每次都拦，
# 但换机器仍会提示未知开发者（本地自用足够）。
echo "==> ad-hoc 签名"
codesign --force --deep --sign - "$APP_DIR" 2>&1 | grep -v "replacing existing signature" || true
codesign --verify --verbose=1 "$APP_DIR" 2>&1 | tail -2

if [ "${1:-}" = "--install" ]; then
    echo "==> 安装到 /Applications"
    # 正在运行的话先退出，否则替换后仍是旧进程
    pkill -f "/Applications/${APP_NAME}.app" 2>/dev/null || true
    rm -rf "/Applications/${APP_NAME}.app"
    cp -R "$APP_DIR" /Applications/
    echo "已安装：/Applications/${APP_NAME}.app"
else
    echo "已生成：${APP_DIR}"
    echo "安装请加 --install"
fi
