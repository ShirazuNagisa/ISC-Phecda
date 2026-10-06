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
| 反代监听 **443** | 低端口（<1024）在沙箱里绑不了 | 改用高端口；**443 由隧道在 Cloudflare 侧承担** |
| 下载并执行解释器 | 违反 2.5.2 | 随包内置 |
| Java / .NET 的 JIT | 需要 `com.apple.security.cs.allow-jit` | 加 entitlement |
| 加载 `libisc.dylib` | 与主程序不同签名的 dylib 需要 `disable-library-validation` | 加 entitlement（同一 Team 签名则不需要） |
| 管理 DNS / ACME / 出站请求 | ✅ 只需 `network.client` | — |
| 装 launchd agent、改系统配置 | ❌ 完全不可用 | 产品里本来就没有（那个 agent 是我验证期的临时物，已删） |

**数据迁移有个硬伤值得先想清楚**：沙箱应用**没有权限读取**旧的
`~/Library/Application Support/ISC Phecda`。所以"自动迁移老用户的数据"做不到 ——
要么让用户重新配置，要么先发一个非沙箱版本、由它把数据搬进容器，再发沙箱版本。
后者是唯一平滑的路子，但意味着**两个版本要按顺序发布**。

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
- `Scripts/build-app.sh` 退役为校验脚本（或删除）；`Documentation/SDK.md` 里
  那段 rpath 说明要重写 —— 工程产出的是 .app，`@executable_path/../Frameworks`
  那条 rpath 这时才真正成立。

### 阶段 2 · 沙箱适配

- Go 侧 `internal/paths`：数据目录改为容器内路径（由环境变量或参数注入，
  内核不该猜自己跑在不在沙箱里）。
- Swift 侧 `AppModel` 同样改。
- 反向代理默认端口从 443 改到高端口；**对外仍然没有端口号**，因为 TLS 在
  Cloudflare 边缘终结、443 由它承担。

### 阶段 3 · 内置运行时

- 复用 `internal/artifacts` 的校验机制，但把"下载"换成"从 bundle 复制"。
- 删掉下载代码路径（不是禁用）。
- 确认 Java 是 OpenJDK 构建。

### 阶段 4 · 签名、归档、上传

- `xcodebuild archive` + 上传 App Store Connect；
- 逐条对照 App Review Guidelines 自查。

## 这份计划里我最不确定的一点

**1.0 GB 的内置运行时是否能过审，我无法预先确认。** 2.5.2 管的是"下载"，内置
不违规；但一个 GB 级的开发者工具类应用会不会被以别的理由打回，取决于审核员的
判断。**建议先提交一版只内置 PHP/Python 的最小版本试水**，通过之后再逐步加回
运行时 —— 而不是一次投入全部工作量然后被一个非技术理由卡住。
