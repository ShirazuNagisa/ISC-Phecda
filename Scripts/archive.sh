#!/usr/bin/env bash
#
# 归档并导出上架用的包。
#
# # 这个脚本**跑不通**，除非先满足下面几件事
#
# 它需要你 Apple 开发者账号里的东西，那些我没法代做：
#
#   1. Xcode 里登录了开发者账号（Settings → Accounts）；
#   2. 有一张 **Apple Distribution**（或 Mac App Store 分发）证书；
#   3. App ID `app.isc.phecda` 已在开发者后台登记；
#   4. 一份 Mac App Store 的 provisioning profile。
#
# 缺任何一件，xcodebuild 都会停在签名那一步 —— 那是**预期**的失败，不是
# 这个脚本写错了。想确认脚本本身对不对，看它有没有走到 "CodeSign"。
#
# # 为什么内置运行时在这一步之前就完成了
#
# 归档会触发一次完整的 Release 构建，而构建阶段 "Bundle Runtimes" 排在
# CodeSign 之前 —— 所以运行时已经在包内、也被签名覆盖了。这正是它必须
# 在那里的原因：签名不覆盖之后才放进包里的文件。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARCHIVE="${ISC_ARCHIVE_PATH:-$ROOT/Build/Phecda.xcarchive}"
EXPORT="${ISC_EXPORT_PATH:-$ROOT/Build/export}"

# 内置哪几个运行时。上架版本**必须**内置（App Review 2.5.2 禁止下载并执行
# 代码），而放哪几个是打包决定 —— 改这里那一行即可，内核不用动。
#
#   php python                   ≈ 110 MB   最小版本，建议先过审
#   php python java              ≈ 450 MB
#   php python java dotnet       ≈ 1.0 GB
export ISC_BUNDLED_RUNTIMES="${ISC_BUNDLED_RUNTIMES:-php python}"

echo "→ 内置运行时：$ISC_BUNDLED_RUNTIMES"
if [ -n "${DEVELOPMENT_TEAM:-}" ]; then
  echo "→ 团队：$DEVELOPMENT_TEAM"
else
  echo "⚠️  没有设置 DEVELOPMENT_TEAM，签名会走 Xcode 里已登录的账号。"
fi

rm -rf "$ARCHIVE" "$EXPORT"
mkdir -p "$EXPORT"

xcodebuild archive \
  -project "$ROOT/Phecda.xcodeproj" \
  -scheme Phecda \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  ${DEVELOPMENT_TEAM:+-development-team "$DEVELOPMENT_TEAM"} \
  -archivePath "$ARCHIVE"

echo "→ 归档完成：$ARCHIVE"

xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$EXPORT" \
  -exportOptionsPlist "$ROOT/Scripts/ExportOptions-AppStore.plist"

echo "→ 导出的包："
ls -la "$EXPORT" | awk 'NR>3 {printf "    %-52s %s\n", $9, $5}'
echo
echo "下一步：用 Transporter 上传 $EXPORT 里的 .pkg，或在 Xcode 的"
echo "Organizer 里选这个归档点 Distribute App。"
