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
    echo "  ❌ $key —— 缺失（${why}）"
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
  echo "     检查 AppIcon.icon 是否在**应用 target 编译的**资源目录里"
  fail=1
fi

# 图标必须带**外观变体**（深浅色各一套）。
#
# 这一条防的是静默失败：图标编译不进去时 actool 只给 warning，构建照样成功；
# 而"深色变体丢了"更隐蔽 —— 旧写法把 `luminosity: dark` 放在 appiconset 里，
# `actool --platform macosx` 没有那个槽位，10 张深色图被当作 "unassigned
# children" 丢掉，产物里带外观变体的图标是 **0 条**，而浅色那份一切正常。
# 用户看到的是"深色模式下图标不对"，从这里查不出任何线索。
#
# 断言直接读编译产物：Assets.car 里 AppIcon 至少有一条带 Appearance。
if [ -f "$APP/Contents/Resources/Assets.car" ]; then
  APPEARANCES="$(xcrun assetutil --info "$APP/Contents/Resources/Assets.car" 2>/dev/null \
    | python3 -c '
import json, sys
try:
    entries = json.load(sys.stdin)
except Exception:
    print(0); raise SystemExit
print(sum(1 for e in entries if e.get("Name") == "AppIcon" and e.get("Appearance")))' 2>/dev/null || echo 0)"
  if [ "${APPEARANCES:-0}" -gt 0 ]; then
    echo "  ✅ AppIcon 带外观变体（$APPEARANCES 条：深浅色/Tinted）"
  else
    echo "  ❌ 包内 AppIcon 一条外观变体都没有 —— 深色模式会拿到浅色那张图"
    echo "     图标要从 Apps/Phecda/AppIcon.icon 编译（Icon Composer 文档），"
    echo "     不是 appiconset：macOS 的 actool 没有 appiconset 的深色槽位"
    fail=1
  fi
fi

# 沙箱必须开着 —— 上架版本没有它会被直接拒。
if codesign -d --entitlements - "$APP" 2>/dev/null | grep -q "com.apple.security.app-sandbox"; then
  echo "  ✅ com.apple.security.app-sandbox"
else
  echo "  ❌ 没有沙箱 entitlement —— Mac App Store 要求必须开启"
  echo "     归档要用 Scripts/archive.sh（它会切到 Phecda-AppStore.entitlements）"
  fail=1
fi

# 内置运行时：上架版**必须**有，而且必须是解压好、签过名的。
#
# # 为什么这三条不能只查一条
#
# 沙箱只允许执行 /Applications 子树与系统目录，所以运行时只能以可执行文件
# 的形态待在包里。缺了、只有归档没有解压、或者解压了没签名，三种情况的
# 现象在本地都可能是"看起来没装运行时"，而上架后分别是"站点起不来"
# "站点起不来"和"上传被拒"。分开查，报错才能指向该改的那一处。
RUNTIMES_DIR="$APP/Contents/Resources/runtimes"
if [ ! -d "$RUNTIMES_DIR" ]; then
  echo "  ❌ 包里没有 Contents/Resources/runtimes —— 上架版必须内置运行时（沙箱不允许执行包外的二进制）"
  fail=1
else
  CORE_DIR="${ISC_CORE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/ISC-Core}"
  MANIFEST=""
  if [ -d "$CORE_DIR" ]; then
    MANIFEST="$(cd "$CORE_DIR" && CGO_ENABLED=0 go run ./Scripts/manifestdump darwin/arm64 2>/dev/null || true)"
  fi

  bundled=0
  while IFS= read -r kind_dir; do
    [ -n "$kind_dir" ] || continue
    kind="$(basename "$kind_dir")"
    while IFS= read -r version_dir; do
      [ -n "$version_dir" ] || continue
      version="$(basename "$version_dir")"
      bundled=$((bundled + 1))

      # 期望的可执行文件取自内核清单 —— 与内核解析时用的是同一份数据源，
      # 这里再猜一遍路径就等于给"构建脚本和内核不同步"留了口子。
      executable="$(printf '%s\n' "$MANIFEST" | awk -F'\t' -v k="$kind" '$1==k{print $7}')"
      if [ -z "$executable" ]; then
        echo "  ⚠️  ${kind}：内核清单里没有这个运行时，无法核对可执行文件"
      elif [ -f "$version_dir/$executable" ]; then
        echo "  ✅ $kind $version → $executable"
      else
        echo "  ❌ $kind $version 里没有 $executable —— 内核会认为这个运行时不可用"
        fail=1
      fi

      # 包内每个 Mach-O 都要签过名，否则上传会被拒。
      unsigned=0
      while IFS= read -r -d '' f; do
        case "$(file -b "$f")" in *Mach-O*) ;; *) continue ;; esac
        codesign --verify --strict "$f" >/dev/null 2>&1 || {
          echo "  ❌ 未签名或签名无效：${f#"$APP"/}"
          unsigned=$((unsigned + 1))
        }
      done < <(find "$version_dir" -type f -print0)
      [ "$unsigned" -eq 0 ] || fail=1
    done < <(find "$kind_dir" -mindepth 1 -maxdepth 1 -type d | sort)
  done < <(find "$RUNTIMES_DIR" -mindepth 1 -maxdepth 1 -type d | sort)

  if [ "$bundled" -eq 0 ]; then
    echo "  ❌ runtimes 目录是空的 —— 构建阶段没有真的放进运行时"
    fail=1
  else
    echo "  ✅ 内置运行时合计 $(du -sm "$RUNTIMES_DIR" | awk '{print $1}') MB"
  fi
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
