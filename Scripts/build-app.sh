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
