#!/bin/sh
# 先单独签一次可执行文件。
#
# # 为什么需要这一步
#
# codesign 对"主可执行文件未签名"的 bundle 会**拒绝一次性签名**，报：
#
#     ISC Phecda.app: code object is not signed at all
#     In subcomponent: .../ISC Phecda.app/Contents/MacOS/ISC Phecda
#
# 而单独签那个文件却成功 —— 实测先签文件、再让 Xcode 签 bundle 就能过。
# 产物里的二进制上根本没有 LC_CODE_SIGNATURE（otool -l 查得到），所以
# "not signed at all" 是实话，只是它不肯顺手补上。
#
# # 只在 ad-hoc 签名时做
#
# 用真实证书分发时交给 Xcode：抢先在可执行文件上盖一个 ad-hoc 签名，
# 反而会让后续的正式签名多一层要处理的东西。
set -e
[ "$CODE_SIGN_IDENTITY" = "-" ] || exit 0
[ -n "$TARGET_BUILD_DIR" ] || exit 0
[ -n "$EXECUTABLE_PATH" ] || exit 0
codesign --force --sign - "$TARGET_BUILD_DIR/$EXECUTABLE_PATH"
