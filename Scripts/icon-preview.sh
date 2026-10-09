#!/usr/bin/env bash
#
# 把 Apps/Phecda/AppIcon.icon 在**六种外观**下渲染成 PNG，用来肉眼检查深浅色。
#
# # 为什么需要它
#
# 图标的外观变体（默认 / 深色 / Tinted / Clear）是**系统**在运行时合成的，
# 编译产物里只有一堆 `IconGroup` / `IconImageStack` 记录，看不出长什么样。
# 而"深色模式到底用了哪张图"这件事，在改完 `icon.json` 之后必须看得见 ——
# 否则只能靠"上传一次、装到手机/Mac 上看一眼"来验证。
#
# 渲染用的是 Icon Composer 自带的 `ictool`（未公开文档，但它是唯一能离线
# 渲染 .icon 的东西）。它列出的 rendition 名就是下面这六个，写错会被它拒绝
# 并把这六个名字念给你听。
#
# 用法：
#
#   Scripts/icon-preview.sh                 # 输出到 Build/icon-preview/
#   ISC_ICON_PREVIEW_SIZE=1024 Scripts/icon-preview.sh
#   open Build/icon-preview                 # 看一眼
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ICON="$ROOT/Apps/Phecda/AppIcon.icon"
OUT="${ISC_ICON_PREVIEW_DIR:-$ROOT/Build/icon-preview}"
SIZE="${ISC_ICON_PREVIEW_SIZE:-512}"

# Icon Composer 随 Xcode 装在 Developer 目录的兄弟位置，不写死 /Applications/Xcode.app。
ICTOOL="$(xcode-select -p)/../Applications/Icon Composer.app/Contents/Executables/ictool"

[ -d "$ICON" ] || { echo "❌ 找不到 $ICON" >&2; exit 1; }
[ -x "$ICTOOL" ] || {
  echo "❌ 找不到 ictool：$ICTOOL" >&2
  echo "   它随 Xcode 26+ 的 Icon Composer 一起来。用 xcode-select 指到那个 Xcode 即可。" >&2
  exit 1
}

mkdir -p "$OUT"
for rendition in Default Dark TintedLight TintedDark ClearLight ClearDark; do
  "$ICTOOL" "$ICON" --export-image \
    --output-file "$OUT/AppIcon-$rendition.png" \
    --platform macOS --rendition "$rendition" \
    --width "$SIZE" --height "$SIZE" --scale 1
done

echo "→ 已渲染 ${SIZE}×${SIZE}："
ls -1 "$OUT" | sed 's/^/    /'
echo
echo "看一眼：open $OUT"
