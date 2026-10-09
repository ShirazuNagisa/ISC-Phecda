// v0.4.5 让应用图标跟上系统的深浅色：
//
//   - 应用图标改用 Icon Composer 的 `AppIcon.icon`。macOS 26 起图标的外观变体
//     （默认 / 深色 / Tinted / Clear）走这个格式，旧的 appiconset 表达不了：
//     `actool --platform macosx` 没有 `luminosity: dark` 槽位，那 10 张深色图
//     被当成 "unassigned children" 静默丢掉 —— 产物里带外观变体的图标是 0 条，
//     现在是 3 条（Aqua / DarkAqua / Tintable）加一个图标栈。
//   - 深色那套图放在 `AppIcon.icon/Assets/Phecda-Dark.png`，等设计在 Icon Composer
//     里指派给深色外观（手写 icon.json 表达不了"按外观换图"，实测过十余种形状）。
//   - 新增 `Scripts/icon-preview.sh`：借 Icon Composer 自带的 ictool 把六种外观
//     渲染成 PNG —— 不开 Xcode 也能看见深浅色各长什么样。
//   - 两道防静默失败的守卫：生成器检查 .icon 的结构与它引用的图；
//     check-submission.sh 断言产物里 AppIcon 至少有一条带外观变体。
//
// swift-tools-version: 6.4
import Foundation
import PackageDescription

// v0.4.4 让应用"像个应用"：打开就有界面，点图标就有界面。
//
//   - 启动默认**打开主界面**；设置里的「最小化启动 Phecda」打开后才静默启动
//     （LaunchPreference）。翻这个默认的理由：双击应用什么都不发生，是最容易
//     被当成"它坏了"的形态，而首次引导向导就住在主窗口里。
//   - 点程序坞图标（或在 Finder 里再打开一次）**总是**打开主界面
//     （applicationShouldHandleReopen），窗口被收进程序坞时也会放回来 ——
//     这一条与上面那个开关无关：那一次点击本身就是用户要界面。
//   - 界面区分了「内核正在启动」与「内核未运行」：窗口现在会在内核起来之前
//     就出现，而后者带一个「启动内核」按钮，闪那一下会让人以为启动失败了。
//
// v0.4.3 把「程序坞里有没有图标」交给用户，并让每次验证都能从零开始：
//
//   - 应用默认按**普通应用**启动（程序坞里有图标、能进 Cmd-Tab、有自己的
//     菜单栏），设置里的「不显示应用图标」可以切回只有菜单栏图标的形态
//     （DockIconPreference）。两种形态都保留菜单栏图标，因此关掉它不会
//     让人够不着应用。顺带去掉系统菜单里那一项「设置…」—— 它打开的是
//     一个空 Scene，而本应用的设置在主窗口里。
//   - 新增一次性运行模式（`ISC_PHECDA_FRESH=1`，Apps/Phecda/FreshRun.swift）：
//     数据目录换到临时目录、偏好只留在内存里，退出时删掉临时目录；密钥后端
//     由**启动方**放进环境（`ISC_SECRET_STORE=file`）—— 应用里 setenv 到不了
//     同一进程里的 Go 运行时。真实安装的数据、偏好、钥匙串一个字节都不碰。
//     两个入口：Xcode 里选生成的共享 scheme `Phecda-Fresh`（⌘R 即从零），
//     命令行用 Scripts/fresh-run.sh。
//   - 数据目录的优先级改成 显式参数 → `ISC_DATA_DIR` → 默认位置，与内核
//     自己的约定（ISC-Core 的 paths.EnvDataDir）同名同义；旧数据迁移只在
//     用默认位置时做，否则"全新安装"里会凭空多出上一次的凭据与站点。
//
// v0.4.1 修订「占用」的口径与菜单栏的形态：
//
//   - 菜单栏图标不再每点一次开一个窗口。它弹一个简略信息台（CPU / GPU /
//     内存 / 网络 的 2×2 网格 + 逐站状态），主窗口只能从面板打开，
//     且全局只有一个实例（D39 的内核侧口径）。
//   - 首页四张卡改成"Phecda 自己占了多少"（内核 + 站点进程树），
//     GPU 仍然只能显示设备级利用率，因此明确标注"整机 GPU"。
//   - 启动不再自动打开主窗口：菜单栏常驻应用一启动就弹窗很打扰。
//
// v0.3.0 新增「远程访问」页（D38）：内核的远程面在界面上可开、可配、
// 可配对、可看设备与审计，并且能装 APNs 凭据去验证推送。
//
// v0.2.0 把 Phecda 收敛成纯 GUI：内核以 dylib 包体形式内嵌（D24），
// 运行时供给、应用部署与进程守护、指标与建议全部在 ISC-Core 里。
// 因此这里不再有 ISCSupervisor / PhecdaSupervisor 两个 target ——
// 曾经的 GUI 侧进程守护已经违反 D25（内核独占业务服务生命周期）。

// 内核库所在的绝对路径。
//
// # 为什么需要它
//
// `libisc.dylib` 的 install name 是 `@rpath/libisc.dylib`，因此客户端必须在
// 运行时找到它。下面那几条相对 rpath 覆盖的是 SwiftPM 的产物布局
// （`.build/out/Products/<config>/`，SwiftPM 会把 dylib 拷到可执行文件旁边）。
//
// 但 Xcode 的产物在 DerivedData 下，而 DerivedData 与源码目录**没有任何
// 相对关系** —— 从 `Build/Products/Debug` 往上走多少层都到不了仓库。于是
// 在 Xcode 里 Run 会直接挂在 dyld：Library not loaded。
//
// 因此把仓库里 Vendor/ISC 的绝对路径也加进 rpath。它只在"本机源码构建"时
// 有意义：分发出去的产物在没有这个路径的机器上，dyld 会自然落到后面那几条
// 相对 rpath 上，行为不受影响。
let vendorPath = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("Vendor/ISC")
    .path

let package = Package(
    name: "ISC-Phecda",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "ISCCore", targets: ["ISCCore"]),
    ],
    targets: [
        .systemLibrary(name: "CISC", path: "Vendor/ISC"),
        .target(
            name: "ISCCore",
            dependencies: ["CISC"],
            linkerSettings: [
                .unsafeFlags([
                    "-L", "Vendor/ISC", "-lisc",
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                    "-Xlinker", "-rpath", "-Xlinker", "@loader_path/../../..",
                    "-Xlinker", "-rpath", "-Xlinker", "@loader_path/../../../../Vendor/ISC",
                    "-Xlinker", "-rpath", "-Xlinker", vendorPath,
                ])
            ]
        ),
        .testTarget(name: "ISCCoreTests", dependencies: ["ISCCore"]),
    ]
)
