# Mac App Store 上架

> 状态：**未开始实施**。这份文件是施工计划与已定结论，不是进度报告。
> 目标：让 Phecda 通过 Mac App Store 审核并上架。

## 三个约束，只有一个是许可问题

### 1. GPLv3 —— 已解决

三个仓库都是 GPLv3，而 App Store 的分发条款与 §10 不相容。已按 **GPLv3 §7**
授予附加许可：各仓库的 `LICENSE-EXCEPTION-APPSTORE.md`。

它**只增加权限、不改变许可**，并且只覆盖 App Store 这一条分发路径。依赖已核查：
ISC-Core 的 111 个 Go 模块里没有传染性许可，唯一的 GPL 就是项目自己 —— 因此
版权人有权单方授予。

### 2. App Review 2.5.2 —— 产品问题，未解决

> Apps should be self-contained. They may not download, install, or execute code
> which introduces or changes features or functionality of the app.

而现在的核心工作方式**正是如此**：内核在运行时下载运行时并执行用户的代码。

实测体积（本机缓存）：

| 运行时 | 体积 |
|---|---|
| .NET | 603 MB |
| Java | 336 MB |
| Python | 68 MB |
| PHP | 42 MB |
| **合计** | **≈ 1.0 GB** |

**唯一的合规路径是把它们随包内置。** 下载路径在 App Store 版本里必须彻底关掉 ——
不是"默认不下载"，而是代码路径不存在，否则审核会看到它。

两个必须一起解决的点：

- **体积**：内置后 .app 会到 GB 级。可选做法是按需分发（App Thinning 对 macOS
  不适用），或者砍掉部分运行时（.NET 与 Java 占了 94%）。
- **再分发许可**：.NET 是 MIT，PHP/Python 是宽松许可；**Java 要确认用的是
  OpenJDK 构建**（Oracle JDK 的再分发条款不适用于随应用分发）。

### 3. App Sandbox —— 工程问题，未解决

Mac App Store 强制开启沙箱，而当前实现有若干处与之冲突：

| 现在的做法 | 沙箱下 | 对策 |
|---|---|---|
| 数据目录 `~/Library/Application Support/ISC Phecda` | **沙箱应用完全读不到这个路径** | 迁进容器；见下面的迁移问题 |
| 反代监听 **443** | ✅ **实测可以**（见下） | 不需要改 |
| 下载并执行解释器 | 违反 2.5.2 | 随包内置 |
| Java / .NET 的 JIT | 需要 `com.apple.security.cs.allow-jit` | 加 entitlement |
| 加载 `libisc.dylib` | 与主程序不同签名的 dylib 需要 `disable-library-validation` | 加 entitlement（同一 Team 签名则不需要） |
| 管理 DNS / ACME / 出站请求 | ✅ 只需 `network.client` | — |
| 装 launchd agent、改系统配置 | ❌ 完全不可用 | 产品里本来就没有（那个 agent 是我验证期的临时物，已删） |

**数据迁移有个硬伤值得先想清楚**：沙箱应用**没有权限读取**旧的
`~/Library/Application Support/ISC Phecda`。所以"自动迁移老用户的数据"做不到 ——
要么让用户重新配置，要么先发一个非沙箱版本、由它把数据搬进容器，再发沙箱版本。
后者是唯一平滑的路子，但意味着**两个版本要按顺序发布**。

## 阶段 1 实测到的两件事（已修正一次误判）

### 1. `CFBundleExecutable` 必须跟着 `PRODUCT_NAME` 走

它写死成 `ISCPhecda`，而工程的 `PRODUCT_NAME` 是 `"ISC Phecda"`。一个不一致
解释了**三个看起来无关的症状**：

- codesign 找不到主可执行文件 → `code object is not signed at all`（构建失败）；
- entitlements **没有**被写进签名（`.xcent` 里 7 条齐全，签出来一条都没有）；
- LaunchServices 报 `The application cannot be opened because its executable
  is missing` —— 而产物里二进制明明在。

改成 `$(EXECUTABLE_NAME)` 之后三者一起消失。当时我先加了一个"先签可执行文件
再签 bundle"的构建阶段，那是**在给症状打补丁**；根因修掉后它就不需要了，已删。

### 2. `libisc.dylib` 必须进 bundle 并用同一身份重签

用真实证书（Team `5Q2A46685M`）签名后，应用启动即被 dyld 拒绝：

```
Library not loaded: @rpath/libisc.dylib
code signature ... not valid for use in process:
mapping process and mapped file (non-platform) have different Team IDs
```

这是**库验证**，不是沙箱。ad-hoc 签名没有 Team ID，所以反而能加载 —— 这也是
为什么它一直"看起来是好的"。

App Store 的要求很明确：dylib 放进 `Contents/Frameworks/`，用与应用相同的身份
签名（Xcode 里就是 Embed & Sign）。当前它放在仓库的 `Vendor/ISC/` 并通过绝对
rpath 引用，那条路在签名分发下走不通。

## 沙箱已生效 —— 以及它立刻暴露的第一个问题

把 `libisc.dylib` 嵌进 bundle 并签名之后，沙箱**确实生效了**（实测：容器
`~/Library/Containers/app.isc.phecda` 被创建，内核自己报的数据目录也在容器里）。

于是阶段 2 的清单上立刻多了一条，而且是实测出来的：

```
本地管理通道建立失败，降级为仅回环
套接字路径过长（112 字节；macOS 上限 104）
.../Containers/app.isc.phecda/Data/Library/Application Support/ISC Phecda/Kernel/run/isc.sock
```

容器前缀把数据目录撑长了 39 字节：

| | 路径长度 |
|---|---|
| 容器外 | 73 字节 ✅ |
| 容器内 | **112 字节** ❌（上限 104） |

内核的降级是对的（自动退回回环 TCP，功能不受影响），但"能用"和"该这样"是
两回事 —— 一个只剩回环的管理通道比 Unix 域套接字少一层 ACL 防护。**数据目录
必须换到容器内更短的位置**（例如 `Library/Application Support/Phecda`），
这是阶段 2 的第一件事。

## 两条实测纠正（阶段 2）

### 「沙箱绑不了低端口」是错的

计划里写着要"把反代默认端口从 443 改成高端口"。**实测推翻了这个前提**：
沙箱应用以普通用户身份在 `*:443` 上监听成功，`curl http://127.0.0.1:443/`
返回 404（没有匹配路由），进程属主是 `shirazu` 而不是 root。

低端口需要特权是 **Linux** 的规则（`CAP_NET_BIND_SERVICE`），macOS 没有这条
限制。我把它当成通用规则写进了计划，没有先验证。

因此**端口不需要改**，对外"地址里不带端口号"这件事天然成立。

### 套接字路径已修好

容器前缀把数据目录撑长了 39 字节，`sun_path` 超限（112 > 104）。数据目录从
`Application Support/ISC Phecda/Kernel` 缩短为 `Application Support/Phecda`：

| | 套接字路径 |
|---|---|
| 修改前 | 112 字节 ❌ |
| 修改后 | **101 字节** ✅ |

实测：降级警告消失，`isc.sock` 在容器内正常建立。

**但这仍是余量有限的修法** —— 现在只差 2 字节，用户名再长几位照样会超。
真正稳的做法是让内核不依赖绝对路径长度（例如先 chdir 到数据目录再绑定相对
路径）。没做，因为改动落在 `internal/platform` 的端点层，影响面比这一处
配置大；当前内核的降级是安全的（退回回环 TCP，功能不受影响），所以留作已知项。

## 关于沙箱的一个纠正（上一轮的误判）

早先我根据"没有创建容器"判断沙箱没生效，并据此写过结论。**那个判断的依据
不成立**：ad-hoc 签名下沙箱本就不生效，而换成真实身份后进程还没走到沙箱就
因为上面的 dylib 问题被 dyld 杀了。**沙箱是否按预期工作，目前仍未验证** ——
要等 dylib 嵌入之后才能测。

## 分阶段施工

### 阶段 0 · 只有你能做

- Apple Developer Program 会员资格；
- Mac App Store 分发证书 + App ID + provisioning profile；
- 决定运行时策略：**全部内置**（~1 GB）还是**砍掉 .NET/Java**（~110 MB，
  只留 PHP 与 Python，产品定位随之收窄）。

### 阶段 1 · 工程形态（`.xcodeproj` 当根 + 本地包依赖）

- 用 **XcodeGen** 生成工程，而不是手写 `project.pbxproj`：`project.yml` 是文本、
  可 diff、可 review，而 pbxproj 是 Xcode 生成的、冲突时几乎没法手工合。
  （本机未装，需 `brew install xcodegen`。）
- `ISCApp` 从 `executableTarget` 改为**库 target**，另加一个极薄的 app 入口
  target（`@main` 必须在可执行 target 里，而 App Store 应用由工程产出）。
- `ISCCore` 作为本地包依赖保持不变。
- 签名、entitlements、Hardened Runtime 收进工程配置。
- ~~`Scripts/build-app.sh`~~ **已删除** —— 它比"失效"更糟：拷的是 .build 里过时
  的二进制，还在旧目录上盖章报成功。~~`SDK.md` 的 rpath 说明~~ **已重写**为
  "How the library is found"，区分应用（嵌入 bundle）与测试（仓库路径）两种。

### 阶段 2 · 沙箱适配

- Go 侧 `internal/paths`：数据目录改为容器内路径（由环境变量或参数注入，
  内核不该猜自己跑在不在沙箱里）。
- Swift 侧 `AppModel` 同样改。
- 反向代理默认端口从 443 改到高端口；**对外仍然没有端口号**，因为 TLS 在
  Cloudflare 边缘终结、443 由它承担。

### 阶段 3 · 内置运行时

**机制已就位**（Core，`internal/runtime`）：

- `UseBundle(dir)` —— 声明内置运行时的位置，Provision **包内优先**；
- `SetDownloader(nil)` —— 这份构建**没有下载能力**，内置缺失时返回
  `ErrNotBundled` 而不是悄悄去下载。

接缝很干净：Provision 从取回归档之后，整条链路（校验 → 解压 → 落位）本来
就只作用在一个本地路径上，所以只加了分支，后面一行没动。**包内那份照样过
摘要校验** —— "它在包里"不是跳过校验的理由。

**再分发许可已核查**：内置意味着要随应用分发这些运行时，来源逐个看过：

| 运行时 | 来源 | 许可 |
|---|---|---|
| Java | `github.com/adoptium/temurin21-binaries`（`OpenJDK21U-jdk_…`） | **OpenJDK（Temurin）**，GPLv2+CE ✅ |
| .NET | `builds.dotnet.microsoft.com` | MIT ✅ |
| PHP | `dl.static-php.dev` | static-php-cli，MIT ✅ |
| Node | `nodejs.org` | MIT ✅ |
| Go | `go.dev` | BSD-3 ✅ |

计划里那条"确认 Java 是 OpenJDK 构建"**已经满足**，不需要换来源。

**打包**：`Scripts/bundle-runtimes.sh` 把清单里指定的归档取回、校验摘要、放进
`Contents/Resources/runtimes/`。**内置哪几个是脚本开头的一行**（默认
`php python`）—— 那是打包决定，不是代码决定，内核一行都不用动。

**已端到端验证**（2026-10-06）：

- 脚本取回 php 8.5.8、SHA-256 校验通过、落进包内 15,106,458 字节；
- 内核启动后改报「运行时来源：应用包内置」；
- 经 REST 触发一次真实安装，任务在**同一毫秒内**完成
  （`created_at` 与 `finished_at` 相同）—— 15 MB 的下载不可能这么快，
  证明它确实取自包内而非网络。

## 一次自己造成的误判（记下来免得重犯）

中途我一度认为"`runtime.json` 重启后没更新"是个产品 bug：删掉它、重启应用、
它却没有重新出现。**那是我的测试脚手架坏了**，不是产品问题。

原因：我为了让包里的运行时生效，跑了一次
`codesign --force --deep --sign - <app>` —— **没带 `--entitlements`**。
这一步把沙箱权限签丢了，应用于是没进沙箱、用的是真实 home 路径
（`~/Library/Application Support/Phecda`），而我只在沙箱容器里找那个文件，
当然找不到。

教训是具体的：**`codesign --force` 不带 `--entitlements` 会静默清空权限**，
而症状与应用逻辑完全无关（路径变了、沙箱没了），很容易被当成产品 bug 去查。

**尚未做**：真正把下载代码从 App Store 那份二进制里去掉已经在 Core 侧做了
（`appstore` 构建标签）。剩下的只有"决定内置哪几个"与阶段 4。

- 复用 `internal/artifacts` 的校验机制，但把"下载"换成"从 bundle 复制"。
- 删掉下载代码路径（不是禁用）。
- 确认 Java 是 OpenJDK 构建。

### 阶段 4 · 签名、归档、上传

脚本与配置已就位（`Scripts/archive.sh`、`Scripts/ExportOptions-AppStore.plist`），
但**跑不通** —— 它需要下面这些，全都在你的开发者账号里：

| 需要什么 | 在哪 |
|---|---|
| Xcode 里登录开发者账号 | Settings → Accounts |
| **Apple Distribution** 证书（Mac App Store 分发） | 后台 Certificates |
| App ID `app.isc.phecda` 已登记 | 后台 Identifiers |
| Mac App Store 的 provisioning profile | 后台 Profiles |

缺任何一件，`xcodebuild` 都会停在签名那一步 —— **那是预期的失败，不是脚本
写错了**。想确认脚本本身对不对，看它有没有走到 `CodeSign`。

跑法：

```bash
DEVELOPMENT_TEAM=<你的团队 ID> Scripts/archive.sh
```

`ISC_BUNDLED_RUNTIMES` 默认 `php python`（≈110 MB）。要改内置哪几个，
`archive.sh` 里有一行注释写着三档体积。

**归档会自动触发一次 Release 构建**，而构建阶段 "Bundle Runtimes" 排在
CodeSign 之前 —— 所以运行时已经在包内、也被签名覆盖了。这正是它必须在
那里的原因：签名不覆盖之后才放进包里的文件。

#### 上传前建议自查

- **2.5.2**：确认包内没有下载并执行代码的路径（`appstore` 构建标签已处理，
  可用 `strings` 在 `.pkg` 里的可执行文件上搜 `ErrNoDownloader` 反查）；
- **沙箱**：确认 entitlements 里有 `com.apple.security.app-sandbox`
  （`codesign -d --entitlements -` 看）；
- **体积**：`Contents/Resources/runtimes/` 的大小决定下载时长，也是审核
  可能提问的地方。

### 阶段 4 的原始计划

- `xcodebuild archive` + 上传 App Store Connect；
- 逐条对照 App Review Guidelines 自查。

## 这份计划里我最不确定的一点

**1.0 GB 的内置运行时是否能过审，我无法预先确认。** 2.5.2 管的是"下载"，内置
不违规；但一个 GB 级的开发者工具类应用会不会被以别的理由打回，取决于审核员的
判断。**建议先提交一版只内置 PHP/Python 的最小版本试水**，通过之后再逐步加回
运行时 —— 而不是一次投入全部工作量然后被一个非技术理由卡住。
