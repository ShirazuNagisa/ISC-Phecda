#!/usr/bin/env bash
#
# Xcode 构建阶段：把闭源推送库放进应用包。
#
# # 什么时候真的放
#
#   - Release 配置，**且** Vendor/AP 里真的有库：放；
#   - 其余情况（日常 Debug 构建、从源码自编译）：**静默跳过**。
#
# 跳过不是失败。链接那一侧的口径是一样的：Release 的链接设置由
# Vendor/AP/libiscap.xcconfig 可选地提供，库不在就没有那几条设置。两处合起来
# 保证"库在不在"是唯一的开关 —— 缺了它，应用照样能构建、能运行，只是没有
# 推送能力。
#
# # 为什么放在脚本阶段而不是"拷贝文件"阶段
#
# 拷贝文件阶段（PBXCopyFilesBuildPhase）没法按配置开关：它在 Debug 下也会跑，
# 而库不存在时那是**构建失败**。脚本阶段可以自己判断，跳过是干净的。
#
# # 必须排在签名之前
#
# 脚本阶段天然在 CodeSign 之前跑 —— 与内置运行时同理：签名不覆盖之后才放进
# 包里的文件，那种包在安装时会因签名不符被拒，而错误信息指向的是"资源被修改"。
#
# 但这一条对**代码**比资源更硬：libiscap.dylib 是 Mach-O，必须自己有一份
# 签名，而且要与应用同一个身份 —— 库验证会拒绝 Team ID 不同的 dylib
# （"mapping process and mapped file (non-platform) have different Team IDs"）。
# 所以这里显式重签一次，用的是 Xcode 当前这次构建的身份。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR="$ROOT/Vendor/AP"
LIB="$VENDOR/libiscap.dylib"

if [ "${CONFIGURATION:-}" != "Release" ]; then
  echo "note: 跳过内置推送库（配置 ${CONFIGURATION:-未知}；只有 Release 链接它）"
  exit 0
fi

if [ ! -f "$LIB" ]; then
  echo "note: 这个构建不含推送库（$LIB 不存在）—— 与从源码自编译的形态一致"
  exit 0
fi

if [ -z "${TARGET_BUILD_DIR:-}" ] || [ -z "${FRAMEWORKS_FOLDER_PATH:-}" ]; then
  echo "❌ 这个脚本要在 Xcode 构建阶段里跑（缺 TARGET_BUILD_DIR / FRAMEWORKS_FOLDER_PATH）" >&2
  exit 1
fi

# 进包之前再验一次摘要。
#
# vendor 那一步已经验过，但这一步是**真正把它发出去**的那一步：从"上一个人
# 拷进来"到"这次归档"之间，这个文件有充分的机会被人换掉。摘要不符时停下来，
# 而不是把一个来源不明的二进制签进发行版。
if [ -f "$VENDOR/SHA256SUMS" ]; then
  ( cd "$VENDOR" && shasum -a 256 -c SHA256SUMS >/dev/null ) || {
    echo "❌ Vendor/AP 里的库与 SHA256SUMS 不符 —— 不把它签进包里" >&2
    echo "   重跑 Scripts/vendor-ap.sh 把它换回记录里的那一份。" >&2
    exit 1
  }
else
  echo "⚠️  Vendor/AP/SHA256SUMS 不在，跳过摘要校验" >&2
fi

DEST="$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH"
mkdir -p "$DEST"
install -m 755 "$LIB" "$DEST/libiscap.dylib"

# 用这次构建的身份重签。
#
# ${EXPANDED_CODE_SIGN_IDENTITY} 是 Xcode 解析后的身份（ad-hoc 时是 "-"）；
# 拿不到就退回 ad-hoc —— 本机开发构建要能跑起来，而分发那条路上 Xcode 一定
# 给了身份。
IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:--}"
if [ -z "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
  echo "note: 没有 EXPANDED_CODE_SIGN_IDENTITY，用 ad-hoc 签内置库" >&2
fi
codesign --force --sign "$IDENTITY" --timestamp=none "$DEST/libiscap.dylib"

echo "→ 已内置推送库：$DEST/libiscap.dylib（签名身份 ${IDENTITY}）"
