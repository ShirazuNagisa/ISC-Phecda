#!/usr/bin/env bash
#
# 提交前自检：把 App Store 会在上传时才告诉你的事情**提前**说出来。
#
# # 为什么需要它
#
# 每漏一个必填键，代价是"重新归档 → 重新导出 → 重新上传"，而报错只有一句
# 编号（例如 90242）。这一轮已经这样栽过一次：LSApplicationCategoryType
# 缺失，包都传上去了才知道。
#
# 这里检查的是**能在本地判断**的部分。审核的主观判断（2.5.2、沙箱行为、
# 元数据是否自洽）不在这里，也代替不了真机提交。
set -euo pipefail

APP="${1:?用法: $0 <应用包路径>}"
PLIST="$APP/Contents/Info.plist"
[ -f "$PLIST" ] || { echo "❌ 找不到 $PLIST" >&2; exit 1; }

fail=0
need() {
  local key="$1" why="$2"
  local v
  v=$(plutil -extract "$key" raw "$PLIST" 2>/dev/null || true)
  if [ -z "$v" ]; then
    echo "  ❌ $key —— 缺失（$why）"
    fail=1
  else
    echo "  ✅ $key = $v"
  fi
}

echo "提交前自检："
need LSApplicationCategoryType   "Mac App Store 必填；缺了上传报 90242"
need CFBundleIdentifier          "身份"
need CFBundleShortVersionString  "商店显示的版本"
need CFBundleVersion             "构建号；每次上传必须递增，重复会被拒"
need LSMinimumSystemVersion      "系统要求"
need CFBundleIconName            "商店图标"
need ITSAppUsesNonExemptEncryption "不声明的话每次上传都被追问加密合规"

# 图标文件必须真的在包里。
#
# 只查 CFBundleIconName 不够 —— 键存在但**文件不在**，上传时才报 90236
# （"does not contain an icon of size 512pt x 512pt @2x"）。踩过一次：
# 图标集被挪到了一个不被工程编译的资源目录里，键还在、图没了。
if [ -f "$APP/Contents/Resources/AppIcon.icns" ]; then
  echo "  ✅ Contents/Resources/AppIcon.icns"
else
  echo "  ❌ 包内没有 AppIcon.icns —— 上传会报 90236（图标缺失）"
  echo "     检查 AppIcon.appiconset 是否在**应用 target 编译的**资源目录里"
  fail=1
fi

# 沙箱必须开着 —— 上架版本没有它会被直接拒。
if codesign -d --entitlements - "$APP" 2>/dev/null | grep -q "com.apple.security.app-sandbox"; then
  echo "  ✅ com.apple.security.app-sandbox"
else
  echo "  ❌ 没有沙箱 entitlement —— Mac App Store 要求必须开启"
  fail=1
fi

# 版本号必须与 CFBundleShortVersionString 一致，否则 App Store Connect 上
# 填的版本与二进制对不上。
echo "  ℹ️  上传后记得在 App Store Connect 里填与 CFBundleShortVersionString 相同的版本号"

if [ "$fail" -ne 0 ]; then
  echo
  echo "❌ 自检没通过 —— 现在改比上传后改便宜得多" >&2
  exit 1
fi
echo "✅ 自检通过"
