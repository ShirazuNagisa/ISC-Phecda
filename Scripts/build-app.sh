#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
"$ROOT/Scripts/verify-vendor.sh"
swift build -c release
BIN="$(swift build -c release --show-bin-path)"
APP="$ROOT/Build/ISC Phecda.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
cp "$BIN/ISCPhecda" "$APP/Contents/MacOS/ISCPhecda"
cp "$ROOT/Vendor/ISC/libisc.dylib" "$APP/Contents/Frameworks/libisc.dylib"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

# 把 SwiftPM 的资源 bundle 一并拷进去。
#
# 不拷的后果不是"少个图标"而是**崩溃**：SwiftPM 生成的 Bundle.module 在
# 找不到这个 bundle 时是 fatalError。它在开发机上可能仍然能跑 —— 访问器
# 里有一条指向 .build 的路径兜底 —— 于是问题只在分发出去之后才出现。
RESOURCE_BUNDLE="$BIN/ISC-Phecda_ISCApp.bundle"
if [ ! -d "$RESOURCE_BUNDLE" ]; then
  echo "❌ 找不到 SwiftPM 资源 bundle：$RESOURCE_BUNDLE" >&2
  echo "   先跑 swift build -c release，再重新打包。" >&2
  exit 1
fi
rm -rf "$APP/Contents/Resources/ISC-Phecda_ISCApp.bundle"
cp -R "$RESOURCE_BUNDLE" "$APP/Contents/Resources/"

# 资源目录（应用图标 + 菜单栏图标）编译成 Assets.car。
#
# # 为什么用 actool 而不是 iconutil 做一个 .icns
#
# 深色/浅色两套图标只有**资源目录**能承载：经典的 `.icns` 格式里没有
# "外观变体"这个概念，而 macOS 26 的深色图标正是靠 `appearances` 表达的。
# 走 `.icns` 的话，深色图标会被静默丢掉 —— 系统只会用浅色那张，
# 而这件事在界面上看不出来（用户不会知道"本该有深色版"）。
#
# 菜单栏图标同理：它的 `template-rendering-intent` 也只有资源目录能表达。
#
# `--app-icon AppIcon` 会额外产出 `CFBundleIconName` 需要的信息，
# 所以 Info.plist 里写的是 `CFBundleIconName` 而不是 `CFBundleIconFile`。
ACTOOL_OUT="$ROOT/Build/actool"
rm -rf "$ACTOOL_OUT"
mkdir -p "$ACTOOL_OUT"
xcrun actool "$ROOT/Resources/Assets.xcassets" \
  --compile "$ACTOOL_OUT" \
  --platform macosx \
  --minimum-deployment-target 14.0 \
  --app-icon AppIcon \
  --output-partial-info-plist "$ACTOOL_OUT/partial.plist" \
  --output-format human-readable-text >/dev/null
cp "$ACTOOL_OUT/Assets.car" "$APP/Contents/Resources/Assets.car"
# actool 的产物里有 .icns，直接放进 Resources 满足老的 `CFBundleIconFile` 路径
for f in "$ACTOOL_OUT"/*.icns; do [ -e "$f" ] && cp "$f" "$APP/Contents/Resources/"; done

# 不要对 libisc.dylib 执行 `codesign --force --sign -`。
#
# Go 用 c-shared 产出的库已经带**链接器签名**（adhoc, linker-signed），它是
# 有效的。而重新签名会把这个库签坏：实测签名只覆盖 1151 页（约 4.7 MB），
# 而文件有 19 MB，剩下十几兆全是"未签名的页"。结果是进程一启动就被
# dyld 以 `Code Signature Invalid`（SIGKILL）杀掉 —— 现象是
# `swift test` 只打印一句"测试目标失败"就退出，看不出任何原因。
#
# `--preserve-metadata` 和"先 remove-signature 再签"都一样坏，所以正解是
# 干脆别碰它。
codesign --force --sign - "$APP/Contents/MacOS/ISCPhecda"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
printf '%s\n' "$APP"
