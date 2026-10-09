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
# # 为什么内置运行时必须在归档这一步之前就位
#
# 归档会触发一次完整的 Release 构建，而构建阶段 "Bundle Runtimes" 排在
# CodeSign 之前 —— 运行时会在这时候被解压、**逐个签名**、再放进包里。
# 它必须排在那里的原因是：签名不覆盖之后才加进包里的文件。
#
# 注意包内运行时的签名是**脚本自己做的**（Configs/Runtime.entitlements），
# 不是 Xcode 顺手签的：它们是独立进程，应用那份 entitlement 管不到它们。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# 归档会把 Vendor/ISC 换成 appstore 版本（没有下载能力的那份），
# **结束时无论成败都要还原**。
#
# 不还原的后果很隐蔽：一次失败的归档会把仓库留在那个状态下，而命令行用户
# 与日常开发正依赖默认构建的下载能力。症状会在很久之后出现（运行时装不上），
# 与"某次归档"看不出关系 —— 而那时没人会想到去看 Vendor 里那份库。
VENDOR_BACKUP="$(mktemp -d)"
cp -R "$ROOT/Vendor/ISC/." "$VENDOR_BACKUP/"
restore_vendor() {
  cp -R "$VENDOR_BACKUP/." "$ROOT/Vendor/ISC/"
  rm -rf "$VENDOR_BACKUP"
}
trap restore_vendor EXIT
ARCHIVE="${ISC_ARCHIVE_PATH:-$ROOT/Build/Phecda.xcarchive}"
EXPORT="${ISC_EXPORT_PATH:-$ROOT/Build/export}"

# 内置哪几个运行时。上架版本**必须**内置（App Review 2.5.2 禁止下载并执行
# 代码），而放哪几个是打包决定 —— 改这里那一行即可，内核不用动。
#
# 注意别和内核的运行时环境变量混了：**同名但用途不同**。这里这个（构建期）
# 是"往包里放哪几个"，而 ISC_BUNDLED_RUNTIMES 作为**运行时**环境变量时是
# "包在哪"，由 AppModel 设置。
#
#   php python                   ≈ 106 MB
#   php python node              ≈ 275 MB   ← 默认
#   php python node java         ≈ 730 MB
export ISC_BUNDLED_RUNTIMES="${ISC_BUNDLED_RUNTIMES:-php python node}"

# 这一个开关决定"这是上架构建"。它同时管三件事，三者必须一致：
#
#   1. 沙箱 entitlement（下面 xcodebuild 的 CODE_SIGN_ENTITLEMENTS）；
#   2. 内置运行时（构建阶段 xcode-bundle-runtimes.sh 据此决定放不放）；
#   3. 内核库的 appstore 标签（再下面重建 Vendor/ISC）。
#
# 三者不一致的后果各不相同，但都很难从症状反推：只有沙箱没内置 → 站点起
# 不来且报错是 EPERM；只有内置没沙箱 → 本地全对而审核看到的是另一份二进制。
export ISC_APPSTORE=1

# 先用 appstore 标签重建内核库并换进 Vendor/。
#
# **这一步不能省。** 内核库是预编译进仓库的（Vendor/ISC），而它的默认构建
# **带下载器** —— App Review 2.5.2 禁止应用下载并执行代码，所以上架那份必须
# 用 appstore 标签重编：那个标签会把取回逻辑整个文件排除在编译之外。
#
# 不做的后果很隐蔽：本地一切都正常（包里也确实内置了运行时），而审核看到
# 的那份二进制里仍然有"按需下载"的能力。构建标签做了等于白做。
if [ -n "${ISC_CORE_DIR:-}" ] || [ -d "$ROOT/../ISC-Core" ]; then
  CORE_DIR="${ISC_CORE_DIR:-$ROOT/../ISC-Core}"
  echo "→ 用 appstore 标签重建内核库"
  ( cd "$CORE_DIR" && ISC_BUILD_TAGS=appstore ./scripts/build-libisc.sh )
  for f in libisc.dylib libisc.h SHA256SUMS; do
    cp "$CORE_DIR/dist/$f" "$ROOT/Vendor/ISC/$f"
  done
  "$ROOT/Scripts/verify-vendor.sh"
  # 反查一次：那份库里不该再有下载器独有的错误串。
  if strings "$ROOT/Vendor/ISC/libisc.dylib" | grep -q "artifact request failed"; then
    echo "❌ 内核库里仍然有下载器 —— appstore 标签没生效，先别归档" >&2
    exit 1
  fi
  echo "  ✅ 内核库已确认不含下载器"
else
  echo "⚠️  找不到 ISC-Core（$ROOT/../ISC-Core），跳过内核库重建。"
  echo "   **归档出来的包会带着能下载的内核**，不要拿去上架。" >&2
fi

echo "→ 内置运行时：$ISC_BUNDLED_RUNTIMES"
if [ -n "${DEVELOPMENT_TEAM:-}" ]; then
  echo "→ 团队：$DEVELOPMENT_TEAM"
else
  echo "⚠️  没有设置 DEVELOPMENT_TEAM，签名会走 Xcode 里已登录的账号。"
fi

rm -rf "$ARCHIVE" "$EXPORT"
mkdir -p "$EXPORT"

# -allowProvisioningUpdates 让 xcodebuild 自己去开发者后台登记 App ID 并创建
# 描述文件。不带它就只能用**已经存在于本机**的描述文件，而新项目的 App ID
# 还没登记过 —— 报错是 "No profiles for 'app.isc.phecda' were found"，看起来
# 像描述文件建错了，其实是没人去建。
#
# CODE_SIGN_ENTITLEMENTS 在这里**覆盖**工程里的默认值，这是本次改动的关键：
# 工程默认指向不带沙箱的 Phecda.entitlements（直接分发与日常开发用），
# 只有归档这一条路才切到带沙箱的 Phecda-AppStore.entitlements。
# 写在这里而不是工程里，是因为"这份构建要不要沙箱"是**分发渠道**的决定，
# 而工程文件只能有一个默认值。
xcodebuild archive \
  -allowProvisioningUpdates \
  -project "$ROOT/Phecda.xcodeproj" \
  -scheme Phecda \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  CODE_SIGN_ENTITLEMENTS=Phecda-AppStore.entitlements \
  ${DEVELOPMENT_TEAM:+DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM"} \
  -archivePath "$ARCHIVE"

echo "→ 归档完成：$ARCHIVE"

xcodebuild -exportArchive \
  -allowProvisioningUpdates \
  -archivePath "$ARCHIVE" \
  -exportPath "$EXPORT" \
  -exportOptionsPlist "$ROOT/Scripts/ExportOptions-AppStore.plist"

# 上传前自检 —— 把"上传时才告诉你"的事情提前。
for app in "$EXPORT"/*.app "$ARCHIVE/Products/Applications"/*.app; do
  [ -d "$app" ] && { echo; "$ROOT/Scripts/check-submission.sh" "$app"; break; }
done

echo "→ 导出的包："
ls -la "$EXPORT" | awk 'NR>3 {printf "    %-52s %s\n", $9, $5}'
echo
echo "下一步：用 Transporter 上传 $EXPORT 里的 .pkg，或在 Xcode 的"
echo "Organizer 里选这个归档点 Distribute App。"
