#!/usr/bin/env bash
#
# 把闭源推送库从 ISC-Ap 取进 Vendor/AP，并写出链接设置。
#
# # 它做四件事，顺序不能换
#
#   1. 从 ISC-Ap 的 dist/ 取 libiscap.dylib / libiscap.h / SHA256SUMS；
#   2. **校验摘要** —— 链接一份与记录不符的库，等于把一个 ABI 与行为都不明
#      的二进制塞进发行版，而症状会在运行期以"推送莫名其妙失败"出现；
#   3. 写 Vendor/AP/libiscap.xcconfig —— Release 配置靠它可选地接上推送库；
#   4. 打印接下来该做什么（重新生成工程不是必须的，但值得说清楚）。
#
# # 为什么产物不进 git
#
# 见 Vendor/AP/README.md。一句话：内核库可以由任何人重新编，推送库不行 ——
# 它的源码（连同 APNs 私钥）不在公开仓库里。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$ROOT/Vendor/AP"

# 与 Scripts/archive.sh 找 ISC-Core 的方式一致：默认看同级的兄弟目录，
# 也可以用环境变量指到别处（CI 上源码与产物常常不在同一棵树里）。
AP_DIR="${ISC_AP_DIR:-$ROOT/../ISC-Ap}"
BUILD=0
[ "${1:-}" = "--build" ] && BUILD=1

[ -d "$AP_DIR" ] || {
  cat >&2 <<EOF
❌ 找不到 ISC-Ap：$AP_DIR

   Phecda 的仓库里**没有**这个库的源码，它是有意分开的。
   用 ISC_AP_DIR 指到你的 ISC-Ap 检出，例如：

       ISC_AP_DIR=~/code/ISC-Ap $0

   只想构建一个"没有推送能力"的版本的话，什么都不用做 —— Debug 本来就不链接它，
   Release 在没有 Vendor/AP/libiscap.xcconfig 时也会静默退化成同样的形态。
EOF
  exit 1
}

if [ "$BUILD" -eq 1 ]; then
  echo "→ 构建 ISC-Ap（$AP_DIR/scripts/build.sh）"
  ( cd "$AP_DIR" && ./scripts/build.sh )
fi

DIST="$AP_DIR/dist"
for f in libiscap.dylib libiscap.h SHA256SUMS; do
  [ -f "$DIST/$f" ] || {
    echo "❌ $DIST/$f 不存在 —— 先在 ISC-Ap 里跑 scripts/build.sh（或加 --build）" >&2
    exit 1
  }
done

mkdir -p "$DEST"
cp "$DIST/libiscap.dylib" "$DIST/libiscap.h" "$DIST/SHA256SUMS" "$DEST/"

# 摘要必须验。它是"这份二进制确实是 ISC-Ap 编出来的那一份"的唯一记录 ——
# HTTPS 只保证传输，不保证落地的那个文件是对的。
if ! ( cd "$DEST" && shasum -a 256 -c SHA256SUMS ); then
  cat >&2 <<'EOF'

❌ Vendor/AP 里的库与 SHA256SUMS 不符。

   若刚换了新版 ISC-Ap，重跑一次本脚本即可（三个文件是一起拷的）。
   若没换过版本，就别继续 —— 先弄清这个文件是从哪来的。
EOF
  exit 1
fi

# 让 Release 接上推送库的那份设置。
#
# 写在这里而不是写死在工程里，是为了让"库在不在"成为**唯一**的开关：
# 没有这个文件，Configs/Release.xcconfig 里那行 `#include?` 静默跳过，
# 于是 Release 与 Debug 一样走"没有模块"那条分支 —— 这正是从 GitHub 拿
# 源码自编译的人看到的形态，而且他们不需要改任何东西。
cat > "$DEST/libiscap.xcconfig" <<'EOF'
// 由 Scripts/vendor-ap.sh 生成 —— 手工改动会在下次 vendor 时被覆盖。
//
// 只在**发行版**里接上闭源推送库。这个文件存在 = 库存在。

// 让 Swift 编译器找到 Vendor/AP/module.modulemap，于是 `canImport(CAp)`
// 为真、ApnsService 走真实 C ABI。没有它，同一个源文件走"没有推送能力"
// 那条分支，照样编译。
SWIFT_INCLUDE_PATHS = $(inherited) "$(SRCROOT)/Vendor/AP"

// 链接闭源库。libiscap.dylib 的 install name 是 @rpath/libiscap.dylib，
// 因此链接期要 -L，运行期要 -rpath —— 两条都指向仓库里的 Vendor/AP。
//
// 绝对路径这一条只在"本机源码构建"时有用（DerivedData 与源码目录没有
// 相对关系，从产物往上走多少层都到不了仓库）。分发出去的包里，库在
// Contents/Frameworks 下，由 @executable_path/../Frameworks 命中。
OTHER_LDFLAGS = $(inherited) -L"$(SRCROOT)/Vendor/AP" -liscap -Xlinker -rpath -Xlinker "$(SRCROOT)/Vendor/AP" -Xlinker -rpath -Xlinker "@executable_path/../Frameworks"
EOF

echo "→ 已放入 Vendor/AP："
ls -la "$DEST" | awk 'NR>3 {printf "    %-28s %s\n", $9, $5}'
cat <<'EOF'

下一步：

    python3 Scripts/gen-project.py     # 不是必须的，工程文件与库的存在无关
    xcodebuild -project Phecda.xcodeproj -target Phecda -configuration Release build

验证 Release 真的链上了：

    nm -gU "<产物>/ISC Phecda.app/Contents/MacOS/ISC Phecda" | grep _iscap_
EOF
