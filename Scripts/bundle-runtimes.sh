#!/usr/bin/env bash
#
# 把运行时**解压并签名**后放进应用包，供 App Store 版本使用。
#
# # 为什么是"解压后放进去"，而不是像以前那样只放归档
#
# App Review 2.5.2 禁止应用下载并执行代码，所以上架版必须随包内置运行时。
# 但"内置归档"是不够的：沙箱进程的 process-exec 只放行 /Applications 子树
# 与系统目录，而内核原本把运行时解压到**数据目录（应用的容器）**—— 那个
# 位置可读、可 stat，偏偏执行时 EPERM。
#
# 实测（macOS 27，同一个 node 二进制，只换位置）：
#
#   /Applications/…/node              执行成功
#   ~/Library/Containers/<id>/Data/…  可读，执行 EPERM
#
# 签名与 team 都不是变量：把 Apple 签名的 /bin/echo 复制进容器同样 EPERM。
# 所以运行时的最终落点只能是应用包内，而且必须是**可执行文件的形态**。
# 包内那份由内核的 resolveBundled 直接使用（不复制、不进容器）：
#
#   Contents/Resources/runtimes/<kind>/<version>/<executable>
#
# # 签名为什么必须在这里做
#
# entitlement 按进程生效、不继承。包内这些二进制是独立进程，应用那份
# entitlement 管不到它们，而 App Store 要求包内所有可执行文件都已签名。
# 用 Configs/Runtime.entitlements（JIT、可写可执行内存、关库校验）签。
#
# # 必须排在 CodeSign 之前
#
# 脚本阶段天然在 CodeSign 之前跑。这不是巧合而是必须：签名不覆盖之后才
# 放进包里的文件，那种包在安装时会因签名不符被拒，而错误信息指向的是
# "资源被修改"，看不出是阶段顺序的问题。
set -euo pipefail

# ↓↓↓ 内置哪些运行时：改这一行（归档时也可以用环境变量指定）↓↓↓
#
# 体积参考（本机实测的**解压后**大小，也就是它会给包增加多少）：
#
#   php + python                ≈ 106 MB
#   php + python + node         ≈ 275 MB   ← 默认；node 一个占 169 MB
#   php + python + node + java  ≈ 730 MB
#
RUNTIMES="${ISC_BUNDLED_RUNTIMES:-php python node}"
# ↑↑↑

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORE="${ISC_CORE_DIR:-$ROOT/../ISC-Core}"
PLATFORM="${ISC_PLATFORM:-darwin/arm64}"
CACHE="${ISC_RUNTIME_CACHE:-$ROOT/Build/runtime-cache}"
ENTITLEMENTS="${ISC_RUNTIME_ENTITLEMENTS:-$ROOT/Configs/Runtime.entitlements}"

APP="${1:-${ISC_APP_BUNDLE:-}}"
if [ -z "$APP" ]; then
  echo "用法: $0 <应用包路径，例如 <DerivedData>/…/ISC Phecda.app>" >&2
  echo "     也可以用 ISC_APP_BUNDLE 指定。" >&2
  exit 2
fi
[ -d "$APP" ] || { echo "❌ 找不到应用包：$APP" >&2; exit 1; }

die() { echo "❌ $*" >&2; exit 1; }
mb_of() { du -sm "$1" | awk '{print $1}'; }

# 签名身份：Xcode 构建阶段给 EXPANDED_CODE_SIGN_IDENTITY，手工跑给
# ISC_CODESIGN_IDENTITY。
IDENTITY="${ISC_CODESIGN_IDENTITY:-${EXPANDED_CODE_SIGN_IDENTITY:-}}"

# 上架版**必须**签得成。签名身份缺失时不能"警告后继续"——那样出来的包
# 一路顺利，直到上传才被拒，而报错只会说"某个文件没有签名"。
if [ "${ISC_APPSTORE:-}" = "1" ] && { [ -z "$IDENTITY" ] || [ "$IDENTITY" = "-" ]; }; then
  die "上架构建要求给包内运行时签名，但拿不到签名身份（EXPANDED_CODE_SIGN_IDENTITY 为空或是 ad-hoc）。"
fi
if [ -z "$IDENTITY" ] || [ "$IDENTITY" = "-" ]; then
  echo "⚠️  拿不到签名身份，包内运行时将**不签名** —— 只适合本机试验，不要拿去上架。"
fi

DEST="$APP/Contents/Resources/runtimes"
[ -f "$ENTITLEMENTS" ] || die "找不到 $ENTITLEMENTS"

echo "→ 内置运行时：$RUNTIMES"
echo "→ 目标：$DEST"
echo "→ 缓存：$CACHE"
mkdir -p "$DEST" "$CACHE/trees" "$CACHE/archives" "$CACHE/stamps"

# 清单从内核代码里读，而不是解析 Go 源码 —— 抠字符串在格式稍变时会静默
# 取错，而取错的表现是"内置了但校验不过"，很难查。
MANIFEST="$(cd "$CORE" && CGO_ENABLED=0 go run ./Scripts/manifestdump "$PLATFORM")"

field() { printf '%s' "$1" | cut -f"$2"; }

digest_of() {
  case "$1" in
    sha256) shasum -a 256 "$2" | awk '{print $1}' ;;
    sha512) shasum -a 512 "$2" | awk '{print $1}' ;;
    *) die "不认识的摘要算法：$1" ;;
  esac
}

# fetch_archive <kind> <archive> <digest> <url> <落点>
fetch_archive() {
  local kind="$1" archive="$2" digest="$3" url="$4" out="$5"
  local algo="${digest%%:*}" want="${digest#*:}" got=""

  if [ -f "$out" ]; then
    got="$(digest_of "$algo" "$out")"
    if [ "$got" = "$want" ]; then
      echo "    · 归档缓存命中（摘要已核对）"
      return 0
    fi
    echo "    · 缓存里的摘要不符，重新取"
    rm -f "$out"
  fi

  echo "    · 取 $archive"
  # 代理是可选的：校园网直连某些源很慢，而脚本不该假定本机有代理。
  local curl_args=(--fail --location --silent --show-error --retry 3 --retry-delay 2)
  [ -n "${ISC_DOWNLOAD_PROXY:-}" ] && curl_args+=(--proxy "$ISC_DOWNLOAD_PROXY")
  curl "${curl_args[@]}" --output "$out.part" "$url"
  mv "$out.part" "$out"

  # 摘要一定要验：这条链路的意义就是把"供应链信任"从 HTTPS 换成固定摘要，
  # 内置的那份也不例外（包里的东西同样可能被换掉）。
  got="$(digest_of "$algo" "$out")"
  if [ "$got" != "$want" ]; then
    die "$kind 的摘要不符
   期望 $algo:$want
   实得 $algo:$got"
  fi
  echo "    ✅ 校验通过（${algo}）"
}

# sign_tree <目录>
#
# 只签 Mach-O。判定用 file(1) 而不是扩展名 —— node 的可执行文件就叫
# bin/node，没有后缀；反过来 *.so 里也可能混着文本文件。
sign_tree() {
  local tree="$1" n=0 f
  if [ -z "$IDENTITY" ] || [ "$IDENTITY" = "-" ]; then
    echo "    · 跳过签名（没有签名身份）"
    return 0
  fi
  # 时间戳默认要（Xcode 给分发构建签名时也带它），但留一个关掉的口子：
  # 它需要连 Apple 的时间戳服务，而网络受限时那个失败很像"签名坏了"。
  local ts_args=()
  [ "${ISC_CODESIGN_TIMESTAMP:-}" != "none" ] && ts_args+=(--timestamp)

  # 先粗筛再逐个判定：php/python/node 加起来上万个小文件，全跑 file(1)
  # 会让每次构建多等十几秒。
  local candidates
  candidates="$(find "$tree" -type f \
      \( -perm -u+x -o -name '*.so' -o -name '*.dylib' -o -name '*.node' \) -print)"

  while IFS= read -r f; do
    [ -n "$f" ] || continue
    case "$(file -b "$f")" in
      *Mach-O*) ;;
      *) continue ;;
    esac
    codesign --force --sign "$IDENTITY" \
      --options runtime \
      --entitlements "$ENTITLEMENTS" \
      ${ts_args[@]+"${ts_args[@]}"} \
      "$f" >/dev/null 2>&1 || die "签名失败：$f"
    n=$((n + 1))
  done <<< "$candidates"
  echo "    · 已签名 $n 个 Mach-O"
}

total_mb=0

for kind in $RUNTIMES; do
  line="$(printf '%s\n' "$MANIFEST" | awk -F'\t' -v k="$kind" '$1==k')"
  [ -n "$line" ] || die "清单里没有 ${kind}（平台 ${PLATFORM}）"

  version="$(field "$line" 2)"
  archive="$(field "$line" 3)"
  digest="$(field "$line" 5)"
  url="$(field "$line" 6)"
  executable="$(field "$line" 7)"
  strip="$(field "$line" 8)"

  echo "  · $kind $version"
  tree="$CACHE/trees/$kind/$version"
  stamp="$CACHE/stamps/$kind-$version.identity"
  target="$DEST/$kind/$version"

  # 缓存命中条件：树在**且**是用同一个身份签的。换了身份（本机试验的
  # ad-hoc 与归档的分发证书）必须重签，否则包里带的是别人签过的二进制。
  cached=0
  if [ -f "$tree/$executable" ] && [ "$(cat "$stamp" 2>/dev/null || true)" = "$IDENTITY" ]; then
    cached=1
    echo "    · 复用已解压的缓存树"
  fi

  if [ "$cached" -eq 0 ]; then
    rm -rf "$tree" "$tree.staging"
    mkdir -p "$tree.staging"
    fetch_archive "$kind" "$archive" "$digest" "$url" "$CACHE/archives/$archive"

    if [ "$strip" = "true" ]; then
      tar -xzf "$CACHE/archives/$archive" -C "$tree.staging" --strip-components=1
    else
      tar -xzf "$CACHE/archives/$archive" -C "$tree.staging"
    fi
    [ -f "$tree.staging/$executable" ] || die "$archive 里没有 $executable"
    # 归档里的权限位未必带可执行位（内核对托管运行时也要补这一步）。
    chmod +x "$tree.staging/$executable"
    mv "$tree.staging" "$tree"
    sign_tree "$tree"
    printf '%s' "$IDENTITY" > "$stamp"
  fi

  # 放进包里。用 ditto 而不是 cp：它会连权限位与扩展属性一起搬，
  # 而签名依赖字节完全一致。
  rm -rf "$target"
  mkdir -p "$(dirname "$target")"
  ditto "$tree" "$target"

  [ -f "$target/$executable" ] || die "复制后找不到 $target/$executable"
  if [ -n "$IDENTITY" ] && [ "$IDENTITY" != "-" ]; then
    codesign --verify --strict "$target/$executable" >/dev/null 2>&1 \
      || die "复制进包后签名校验失败：$target/$executable"
  fi
  mb="$(mb_of "$target")"
  total_mb=$((total_mb + mb))
  echo "    ✅ 已放入包内（${mb} MB）"
done

echo
echo "→ 包内运行时（合计 ${total_mb} MB）："
find "$DEST" -mindepth 2 -maxdepth 2 -type d | sort | while IFS= read -r d; do
  printf '    %-58s %s MB\n' "${d#"$DEST"/}" "$(mb_of "$d")"
done
