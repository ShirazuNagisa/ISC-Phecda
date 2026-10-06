#!/usr/bin/env bash
#
# 把运行时归档放进应用包，供 App Store 版本使用。
#
# # 为什么需要这一步
#
# App Review 2.5.2 禁止应用下载并执行代码，而产品原本的工作方式正是如此
# （按需取回 php/python/java/dotnet 再执行）。上架版本必须改为随包内置。
# 内核侧的取用路径已经就位（internal/runtime 的 UseBundle + 自动发现），
# 缺的就是"把归档放进 Contents/Resources/runtimes/"这一步。
#
# # 内置哪几个 = 下面这一行
#
# 这是**打包决定**，不是代码决定。改这一行就换了上架版本的能力集合，
# 内核一行都不用动 —— 它按"包里有没有"来决定用哪个，没有就报
# ErrNotBundled。
#
# 体积参考（本机实测的安装后大小，归档会小一些）：
#
#   php + python                     ≈ 110 MB   ← 最小版本，建议先过审用
#   php + python + java              ≈ 450 MB
#   php + python + java + dotnet     ≈ 1.0 GB
#
set -euo pipefail

# ↓↓↓ 内置哪些运行时：改这一行 ↓↓↓
RUNTIMES="${ISC_BUNDLED_RUNTIMES:-php python}"
# ↑↑↑ 也可以用环境变量覆盖（CI 里按渠道出不同包）↑↑↑

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORE="${ISC_CORE_DIR:-$ROOT/../ISC-Core}"
PLATFORM="${ISC_PLATFORM:-darwin/arm64}"

APP="${1:-}"
if [ -z "$APP" ]; then
  echo "用法: $0 <应用包路径，例如 <DerivedData>/…/ISC Phecda.app>" >&2
  echo "     也可以用 ISC_APP_BUNDLE 指定。" >&2
  exit 2
fi
APP="${ISC_APP_BUNDLE:-$APP}"
[ -d "$APP" ] || { echo "❌ 找不到应用包：$APP" >&2; exit 1; }

DEST="$APP/Contents/Resources/runtimes"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "→ 内置运行时：$RUNTIMES"
echo "→ 目标：$DEST"
mkdir -p "$DEST"

# 清单从内核代码里读，而不是解析 Go 源码 —— 抠字符串在格式稍变时会静默
# 取错，而取错的表现是"内置了但校验不过"，很难查。
MANIFEST="$(cd "$CORE" && CGO_ENABLED=0 go run ./Scripts/manifestdump "$PLATFORM")"

for kind in $RUNTIMES; do
  line="$(printf '%s\n' "$MANIFEST" | awk -F'\t' -v k="$kind" '$1==k')"
  if [ -z "$line" ]; then
    echo "❌ 清单里没有 ${kind}（平台 ${PLATFORM}）" >&2
    exit 1
  fi
  archive="$(printf '%s' "$line" | cut -f3)"
  digest="$(printf '%s' "$line" | cut -f5)"
  url="$(printf '%s' "$line" | cut -f6)"

  if [ -f "$DEST/$archive" ]; then
    echo "  · ${kind}：已在包里，跳过"
    continue
  fi

  echo "  · ${kind}：取 $archive"
  # 代理是可选的：校园网直连某些源很慢，而脚本不该假定本机有代理。
  curl_args=(--fail --location --silent --show-error --retry 3 --retry-delay 2)
  [ -n "${ISC_DOWNLOAD_PROXY:-}" ] && curl_args+=(--proxy "$ISC_DOWNLOAD_PROXY")
  curl "${curl_args[@]}" --output "$WORK/$archive" "$url"

  # 摘要一定要验：这条链路的意义就是把"供应链信任"从 HTTPS 换成固定摘要，
  # 内置的那份也不例外（包里的东西同样可能被换掉）。
  algo="${digest%%:*}"; want="${digest#*:}"
  case "$algo" in
    sha256) got="$(shasum -a 256 "$WORK/$archive" | awk '{print $1}')" ;;
    sha512) got="$(shasum -a 512 "$WORK/$archive" | awk '{print $1}')" ;;
    *) echo "❌ 不认识的摘要算法：$algo" >&2; exit 1 ;;
  esac
  if [ "$got" != "$want" ]; then
    echo "❌ $kind 的摘要不符" >&2
    echo "   期望 $algo:$want" >&2
    echo "   实得 $algo:$got" >&2
    exit 1
  fi

  cp "$WORK/$archive" "$DEST/$archive"
  echo "    ✅ 校验通过（${algo}）"
done

echo "→ 包内运行时："
ls -la "$DEST" | awk 'NR>3 {printf "    %-56s %s\n", $9, $5}'
echo
echo "⚠️  这些文件在**签名之前**放进包里，否则签名不覆盖它们。"
