#!/usr/bin/env bash
#
# 从零开始跑一遍：构建 → 用一次性数据目录启动。
#
# # 它解决什么
#
# 手工验证一个"第一次用"的流程（首次引导、还没有服务商时每一页长什么样、
# 数据目录要不要迁移）需要每次都从零开始，而手工清状态既慢又危险 ——
# 要清的那几处（数据目录、偏好、登录钥匙串）同时也是真实安装正在用的。
# 这个脚本把这件事变成一条命令，而且**一个字节都不碰真实安装**。
#
# 机制一半在应用那一侧（`ISC_PHECDA_FRESH=1`，见 Apps/Phecda/FreshRun.swift）：
# 数据目录换到 $TMPDIR 下的临时目录、所有偏好只留在内存里，正常退出时删掉
# 那个临时目录。另一半（`ISC_SECRET_STORE=file`）必须由**这里**放进启动环境，
# 理由见下面 export 那一段 —— 应用自己 setenv 是没用的。
#
# # 用法
#
#   Scripts/fresh-run.sh                    # Debug 构建，然后前台启动
#   ISC_CONFIG=Release Scripts/fresh-run.sh # Release 构建
#   Scripts/fresh-run.sh --no-build         # 直接用上次的产物
#   Scripts/fresh-run.sh --wipe             # 额外清掉**真实**状态（会问一次）
#   Scripts/fresh-run.sh --wipe --yes       # 同上，不问（脚本/CI 用）
#
# 前台跑（而不是 `open`）是刻意的：内核的结构化日志走 stderr，在这里能直接
# 看见 —— 验证的时候想看的往往正是那几行。
#
# # 从 Xcode 跑的话，用 `Phecda-Fresh` scheme
#
# 同一件事在图形界面里是一键的：**共享** scheme `Phecda-Fresh` 的 Run action
# 里已经设好了那两个环境变量（由 Scripts/gen-project.py 生成，见 write_schemes），
# 日常那个 `Phecda` scheme 照旧用真实数据。两个 scheme 都在仓库里，所以
# "每次从零"不是某个人本机上的设置。
#
# scheme 里的环境变量只对 Xcode 的 **Run** 生效，`xcodebuild build` 不读它 ——
# 命令行这条路要用本脚本，原因就在这里。
#
# # 退出：请用菜单栏里的「退出」
#
# 那个入口会走正常的退出流程（停内核 → 删临时目录）。Ctrl-C 则**不是**：
# 进程被信号杀掉，内核来不及停，临时目录也不会被删 —— 残留由本脚本在最后
# 扫掉，站点进程则可能留在机器上。
#
# 为什么不在应用里接 SIGINT：试过，接不住。内核（libisc）是同一个进程里的
# Go 运行时，进程的信号掩码由它摆布，`signal(2)` 与 dispatch 信号源在这
# 进程里都时灵时不灵（实测同一个 dispatch 源在普通 Swift 程序里正常，在
# 这个应用里一个事件也收不到）。与其留一段"大部分时候不管用"的代码，不如
# 把退出交给本来就可靠的那条路。
#
# # 它**不**清什么
#
# 只清本机这一侧。已经写进 DNS 的解析、已经签发的证书、系统代理设置、
# `isc service install` 装的 launchd 服务都不在里面 —— 那些是对外的动作，
# 清它们要各自的凭据与权限，不该混进一个"重跑一次"的脚本里。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${ISC_CONFIG:-Debug}"
DERIVED="${ISC_DERIVED_DATA:-$ROOT/Build/DerivedData}"
APP="$DERIVED/Build/Products/$CONFIG/ISC Phecda.app"
BUNDLE_ID="app.isc.phecda"
# 进程名（= 可执行文件名，PRODUCT_NAME 是 "ISC Phecda"）。停实例时用它精确匹配。
PROCESS_NAME="ISC Phecda"

# 真实安装的数据目录。与 AppModel.init 里的默认值必须一致；沙箱构建
# （归档出来的那个）用的是容器里的路径，那一份要清就删容器。
REAL_DATA="$HOME/Library/Application Support/Phecda"
LEGACY_DATA=(
  "$HOME/Library/Application Support/ISC Phecda"
  "$HOME/Library/Application Support/ISC"
)

build=1
wipe=0
assume_yes=0
for arg in "$@"; do
  case "$arg" in
    --no-build) build=0 ;;
    --wipe) wipe=1 ;;
    --yes|-y) assume_yes=1 ;;
    # 用法说明就是文件开头那段注释：从头打到第一行非注释为止。
    # 不写死行号 —— 那段注释会变长，写死只会在某天悄悄截掉半段。
    -h|--help) sed -n '2,/^[^#]/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "❌ 不认识的参数：${arg}（--help 看用法）" >&2; exit 2 ;;
  esac
done

# 已经在跑的那个实例必须先停：同一台机器上两个 Phecda 会抢同一批端口
# （反向代理、远程面），而用户看到的是一堆莫名其妙的"端口被占用"。
# 从 Xcode 跑起来的那个也算 —— 它用的是同一份数据目录。
#
# 按**进程名**精确匹配（`-x`），不按命令行（`-f`）：后者会连"命令行里恰好
# 含有这一串"的进程一起杀掉 —— 比如另一个正在执行 pkill 的 shell。
# 进程名就是可执行文件名（PRODUCT_NAME = "ISC Phecda"）。
running_pids() { pgrep -x "$PROCESS_NAME" 2>/dev/null || true; }

if [ -n "$(running_pids)" ]; then
  echo "→ 停止正在运行的实例（PID $(running_pids | tr '\n' ' '))"
  # 顺序是有代价考量的，从最体面到最不体面：
  #
  #   1. Apple Event → 走应用自己的退出流程，内核停干净、站点进程跟着走；
  #   2. SIGTERM    → 进程直接结束，内核来不及停，站点进程会被留下；
  #   3. SIGKILL    → 只留给**卡住**的实例。
  #
  # 第 3 步不是假想：实测有个从 Xcode 起来的旧实例卡在 100% CPU 上跑了三小时，
  # Apple Event 与 SIGTERM 它都当没听见（PPID 已经是 1，没人管它）。那种实例
  # 不退，这个脚本就起不来 —— 所以最后强杀一次，并如实说明代价。
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  for _ in $(seq 1 40); do
    [ -n "$(running_pids)" ] || break
    sleep 0.25
  done
  if [ -n "$(running_pids)" ]; then
    echo "⚠️  它没有响应正常退出请求，改用 SIGTERM" >&2
    pkill -x "$PROCESS_NAME" || true
    for _ in $(seq 1 20); do
      [ -n "$(running_pids)" ] || break
      sleep 0.25
    done
  fi
  if [ -n "$(running_pids)" ]; then
    echo "⚠️  实例卡住了，强杀 PID $(running_pids | tr '\n' ' ') —— 它托管的站点进程可能残留" >&2
    pkill -9 -x "$PROCESS_NAME" || true
    sleep 1
  fi
fi

if [ "$build" -eq 1 ]; then
  echo "→ 构建（${CONFIG} → ${DERIVED}）"
  xcodebuild -project "$ROOT/Phecda.xcodeproj" -scheme Phecda \
    -configuration "$CONFIG" -derivedDataPath "$DERIVED" build >/dev/null
fi

[ -d "$APP" ] || { echo "❌ 没有产物：${APP}（去掉 --no-build 重新构建）" >&2; exit 1; }

if [ "$wipe" -eq 1 ]; then
  cat <<EOF

即将删除**真实安装**的状态（不是一次性运行的那份）：
    数据目录        $REAL_DATA
    旧版数据目录    ${LEGACY_DATA[0]}
                    ${LEGACY_DATA[1]}
    偏好            ~/Library/Preferences/$BUNDLE_ID.plist
    沙箱容器        ~/Library/Containers/${BUNDLE_ID}（含它自己的偏好与数据）
    保存的窗口状态  ~/Library/Saved Application State/$BUNDLE_ID.savedState
    缓存            ~/Library/Caches/$BUNDLE_ID
    钥匙串条目      isc-core / master@<数据目录指纹>
    日志            ~/Library/Logs/Phecda
    隐私授权        tccutil reset All ${BUNDLE_ID}（文件与文件夹等）

    ⚠️ 通知授权**不在这里**：它不在 TCC 里，tccutil 也清不掉
       （实测 `tccutil reset Notifications` 报 Failed）。要重新验证"第一次申请
       通知权限"，得在「系统设置 → 通知」里把 ISC Phecda 那一项删掉。
EOF
  if [ "$assume_yes" -ne 1 ]; then
    printf '确认继续？输入 yes：'
    read -r reply
    [ "$reply" = "yes" ] || { echo "已取消。"; exit 1; }
  fi

  rm -rf "$REAL_DATA" "${LEGACY_DATA[@]}"
  rm -rf "$HOME/Library/Containers/$BUNDLE_ID"
  rm -rf "$HOME/Library/Saved Application State/$BUNDLE_ID.savedState"
  rm -rf "$HOME/Library/Caches/$BUNDLE_ID"
  rm -rf "$HOME/Library/Logs/Phecda"
  # 偏好两条路都走：`defaults` 是规范路径（经 cfprefsd），但**有些机器上
  # 它会失败** —— 只要这个 bundle id 在磁盘上有一个容器，cfprefsd 就会把
  # 这个域重定向到容器里那一份，于是 `defaults delete` 报 "Domain not found"，
  # 而真实的那份 plist 还在。所以再直删一次文件。
  #
  # 删完还要**确认它没有被写回来**：cfprefsd 手里握着该域的缓存，删掉文件
  # 不等于删掉域 —— 它可能随后把整份缓存重新落盘（实测遇到过：删掉的两个键
  # 过了几秒又出现在文件里）。真发生了就重启 cfprefsd 再删一次，那是唯一
  # 能确定缓存也一并丢掉的做法。
  defaults delete "$BUNDLE_ID" 2>/dev/null || true
  rm -f "$HOME/Library/Preferences/$BUNDLE_ID.plist"
  if [ -e "$HOME/Library/Preferences/$BUNDLE_ID.plist" ]; then
    echo "→ 偏好被 cfprefsd 的缓存写了回来，重启它再删一次"
    killall cfprefsd 2>/dev/null || true
    sleep 2
    rm -f "$HOME/Library/Preferences/$BUNDLE_ID.plist"
  fi

  # 隐私授权（文件与文件夹、自动化……）。这一条只有 `--wipe` 会做：它会让
  # 下一次访问受保护目录时**重新弹窗**，而"每次从零"的那个人未必想每次都被
  # 问一遍 —— 所以它属于"清成没装过"，不属于一次性运行模式。
  #
  # 通知授权不在 TCC 里，清不掉（见上面那段说明）。
  tccutil reset All "$BUNDLE_ID" 2>/dev/null || true

  # 主密钥的钥匙串条目。
  #
  # 条目名是 `master@<指纹>`，指纹 = 数据目录**绝对路径**的 sha256 前 4 字节
  # （见 ISC-Core 的 internal/platform/secret_unix.go）。所以它是算出来的，
  # 不是写死的 —— 写死一个指纹只会在换用户名之后静默删错条目。
  #
  # 只删这一条：不带指纹的旧条目 `master` 可能属于**另一个**数据目录
  # （内核自己的安装用的是同一个 service 名），删它越界了。
  SCOPE="$(printf '%s' "$REAL_DATA" | shasum -a 256 | cut -c1-8)"
  if security delete-generic-password -s isc-core -a "master@$SCOPE" >/dev/null 2>&1; then
    echo "→ 已删除钥匙串条目 master@$SCOPE"
  else
    echo "→ 钥匙串里没有 master@${SCOPE}（本来就没有装过，或已经被删）"
  fi
  echo "✅ 真实状态已清空"
fi

# 收尾：把被信号打断的那几次留下的临时数据目录扫掉。
#
# 正常退出时应用自己会删（见 FreshRun.cleanUp），这里只兜底。名字是本脚本
# 自己这一套（`isc-fresh-`），而上面已经把别的实例停掉了，所以不会误删一个
# 正在运行的会话。
sweep() { rm -rf "${TMPDIR:-/tmp}"/isc-fresh-* 2>/dev/null || true; }

# Ctrl-C：bash 会把 SIGINT 也发给前台子进程，子进程死后这里再补一次正常退出
# 请求（应用已经不在时它什么也不做）。这条 trap 的意义是让"用户按了 Ctrl-C"
# 与"用户点了退出"在**清理**这件事上收敛到同一个结果。
on_interrupt() {
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
}
trap sweep EXIT
trap on_interrupt INT TERM

echo "→ 启动：$APP"
echo "  数据目录是本次运行独有的临时目录（应用会在 stderr 上打印它的路径）"
echo "  退出请用菜单栏图标里的「退出」（⌘Q 同效）；Ctrl-C 只能算强杀"
echo

# 一次性运行模式就是全部机制：应用自己换数据目录、把偏好留在内存里。
export ISC_PHECDA_FRESH=1

# 密钥后端必须**由这里**设，不能靠应用里的 setenv。
#
# 内核是同一个进程里的 Go 运行时，而 Go 在库被装载时就把 environ 复制走了：
# 之后再 setenv，`os.Getenv(ISC_SECRET_STORE)` 看不见 —— 实测应用里设过之后
# 内核照样报 `已生成新的主密钥 backend=macos-keychain`，于是每跑一次就往登录
# 钥匙串里多一条 master@…（视图里那条告警就是为这件事准备的）。
export ISC_SECRET_STORE=file

# 前台跑，**不用 exec**：应用退出之后本脚本还要收尾。
"$APP/Contents/MacOS/ISC Phecda"
