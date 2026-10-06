#!/usr/bin/env bash
#
# Xcode 构建阶段：把运行时归档放进应用包。
#
# # 什么时候会真的放
#
#   - Release 配置：默认放（上架版本必须随包内置，见 App Review 2.5.2）；
#   - 或者显式设置了 ISC_BUNDLED_RUNTIMES：CI 按渠道出不同的包时用；
#   - 其余情况（日常 Debug 构建）**跳过** —— 否则每敲一次 Cmd+R 都要下
#     一百多 MB，而开发时根本用不到内置运行时。
#
# # 必须排在签名之前
#
# 脚本阶段天然在 CodeSign 之前跑。这不是巧合而是必须：签名不覆盖之后才
# 放进包里的文件，那种包在安装时会因签名不符被拒，而错误信息指向的是
# "资源被修改"，看不出是阶段顺序的问题。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ "${CONFIGURATION:-}" != "Release" ] && [ -z "${ISC_BUNDLED_RUNTIMES:-}" ]; then
  echo "note: 跳过内置运行时（配置 ${CONFIGURATION:-未知}，且没有设置 ISC_BUNDLED_RUNTIMES）"
  exit 0
fi

if [ -z "${TARGET_BUILD_DIR:-}" ] || [ -z "${WRAPPER_NAME:-}" ]; then
  echo "❌ 这个脚本要在 Xcode 构建阶段里跑（缺 TARGET_BUILD_DIR / WRAPPER_NAME）" >&2
  exit 1
fi

exec "$ROOT/Scripts/bundle-runtimes.sh" "$TARGET_BUILD_DIR/$WRAPPER_NAME"
