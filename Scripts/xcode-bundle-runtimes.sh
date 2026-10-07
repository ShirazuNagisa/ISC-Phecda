#!/usr/bin/env bash
#
# Xcode 构建阶段：把运行时解压、签名后放进应用包。
#
# # 什么时候会真的放
#
#   只有 ISC_APPSTORE=1 时（Scripts/archive.sh 会设）。日常的 Debug 与
#   直接分发 Release 构建都跳过 —— 它们没有沙箱，可以按需下载运行时，
#   包因此小得多（内置 node+php+python 要多占约 275 MB）。
#
#   显式设置 ISC_BUNDLED_RUNTIMES 也会触发（CI 按渠道出不同包时用）。
#
# # 为什么上架版必须放进**解压好的**运行时
#
# 沙箱进程只能 exec /Applications 子树与系统目录。归档放在包里没问题，
# 但内核把解压目标定在数据目录（容器）—— 解出来的二进制就在放行名单之外，
# 于是每个运行时都以 `fork/exec …: operation not permitted` 结束。
# 详见 Scripts/bundle-runtimes.sh 的开头。
#
# # 必须排在签名之前
#
# 脚本阶段天然在 CodeSign 之前跑。这不是巧合而是必须：签名不覆盖之后才
# 放进包里的文件，那种包在安装时会因签名不符被拒，而错误信息指向的是
# "资源被修改"，看不出是阶段顺序的问题。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ "${ISC_APPSTORE:-}" != "1" ] && [ -z "${ISC_BUNDLED_RUNTIMES:-}" ]; then
  echo "note: 跳过内置运行时（ISC_APPSTORE 未设，也没有显式指定 ISC_BUNDLED_RUNTIMES）"
  exit 0
fi

if [ -z "${TARGET_BUILD_DIR:-}" ] || [ -z "${WRAPPER_NAME:-}" ]; then
  echo "❌ 这个脚本要在 Xcode 构建阶段里跑（缺 TARGET_BUILD_DIR / WRAPPER_NAME）" >&2
  exit 1
fi

exec "$ROOT/Scripts/bundle-runtimes.sh" "$TARGET_BUILD_DIR/$WRAPPER_NAME"
