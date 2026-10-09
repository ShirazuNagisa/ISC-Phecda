# 应用图标与菜单栏图标

## 源文件

原始图放在 `Sources/` 下（由设计给出，**JPEG、无 alpha**）：

| 文件 | 用途 |
|---|---|
| `Mizar-Light.jpeg` / `Mizar-Dark.jpeg` | Mizar 的浅色 / 深色应用图标 |
| `Phecda-Light.jpeg` / `Phecda-Dark.jpeg` | Phecda 的浅色 / 深色应用图标 |
| `Phecda-menubar.jpeg` | Phecda 的菜单栏图标 |

## 生成物

| 位置 | 内容 |
|---|---|
| `App/Mizar-iOS/Assets.xcassets/AppIcon.appiconset` | 1024px 亮 + 暗（`platform: ios` 与 `watchos` 两组） |
| `App/Mizar-watchOS/Assets.xcassets/AppIcon.appiconset` | 同上（两个 target 各一份，避免共享目录的成员归属问题） |
| `Apps/Phecda/AppIcon.icon` | **Icon Composer 文档**（`icon.json` + `Assets/`）—— Phecda 应用图标唯一来源，见文末 |
| `Apps/Phecda/Assets.xcassets/AppMark.imageset` | 界面里那张标记图，含 `luminosity: dark` 变体（这张**是**生效的） |
| `Apps/Phecda/Assets.xcassets/MenuBarIcon.imageset` | 18px / 36px（1x/2x），`template-rendering-intent: template` |

## 资源目录为什么要声明在 Package.swift 里

它由 Xcode 工程编译进应用的 `Assets.car`：

- Xcode 工程把整个目录编成 `Assets.car` 放进 `.app`；
- `swift build` / Xcode 走 SwiftPM，把目录编成 `ISCPhecda_ISCApp.bundle`。

**后者需要 Package.swift 里的 `resources:` 声明。** 没有它，SwiftPM 那条路
产物里一个资源都没有 —— 而症状是静默的：`Image("AppMark")` 只是一片空白，
不报错。菜单栏图标也一直受这个影响，只是它有 SF Symbol 兜底所以没人发现。

取用时必须写 `bundle: .module`：`Image("…")` 默认只在**主 bundle** 里找，
从 Xcode 跑时主 bundle 里什么都没有。

应用源码现在由 Xcode 工程直接编译（不再是 SwiftPM target），因此资源走
**主 bundle**，`Image("…")` 用默认查找即可 —— 不再涉及 `Bundle.module`。

## 两个必须做对的地方

### 1. 应用图标不能有 alpha

iOS 会拒绝带透明通道的应用图标。源文件是 JPEG（本来就没有 alpha），
生成时统一 `convert('RGB')`。

### 2. 菜单栏图标必须是模板图

原图是**白色星形配近白背景**，而且右下角有「豆包AI生成」水印。

菜单栏图标靠 `template-rendering-intent` 让系统按菜单栏的明暗自动渲染成
黑或白。不设这一项的话，这个白色的图形在浅色菜单栏上会**完全看不见**。

提取方式（`Phecda-menubar.jpeg` 的亮度直方图很干净：背景 240–249，
星形 255）：

```python
alpha = clip((luminance - 250) / 5, 0, 1)   # 250 以下全透明 → 水印（176–240）自动消失
```

包围盒用**硬掩码的行列计数**算，不能用「有没有一个亮像素」——
JPEG 的背景渐变里散布着零星 >250 的噪点，而"任意一个像素"会被最角落的
那一颗撑满整幅图（实测裁出过负坐标）。

## macOS 的应用图标走 Icon Composer 的 `.icon`（v0.4.5 起）

**`Apps/Phecda/AppIcon.icon` 是 Phecda 应用图标唯一的来源**，用 Icon Composer
（Xcode 26+ 自带，在 Xcode 的 Applications 目录下）编辑。

### 为什么不再用 appiconset

旧写法把 10 张 `luminosity: dark` 的图放进 `AppIcon.appiconset`，而
`actool --platform macosx` **没有那个槽位**：它只给一条

    warning: The app icon set "AppIcon" has 10 unassigned children.

然后把它们静默丢掉 —— 构建成功、图标"有"（浅色那份），只有去数产物才发现：

| | `Assets.car` 里带外观变体的 AppIcon 条目 |
|---|---|
| 改动前（appiconset） | **0**（11 条全是无外观的） |
| 改动后（`.icon`） | **3**：`NSAppearanceNameAqua` / `NSAppearanceNameDarkAqua` / `ISAppearanceTintable`，另有同名 `IconImageStack`（macOS 26 真正用来合成图标的那一层） |

同一个 appiconset 写法在 **iOS 上是有效的**（Mizar 的产物里保留着
`UIAppearanceDark`），所以这不是"图写错了"，是 macOS 这条编译路径不认。

### 工程怎么接的

工程由 `Scripts/gen-project.py` 生成，它把 `.icon` 作为**一个不透明包**加进
Resources 阶段，类型名是 `folder.iconcomposer.icon` —— 这不是随便起的：
Xcode 自己的 `StandardFileTypes.xcspec` 里写着

    Identifier = folder.iconcomposer.icon;
    BasedOn = folder.abstractassetcatalog;
    IsTransparent = NO;          // 当成包，不要拆开

而 `AssetCatalogCompiler.xcspec` 的 `InputFileTypes` 里也有它，也就是**交给
actool 编译**（和 `.xcassets` 同一条路）。类型写错或拆开成散文件的后果是图标
**静默消失**：actool 找不到图标只给 warning，构建照样成功。

### 深色图标怎么做（`.icon` 不给你"按外观换图"，但给你"按外观改属性"）

**图片本身不能按外观特化。** 三条独立证据：

* Icon Composer 的检查器里，`Composition`（含 `Image` / `Visible` / `Layout`）右侧的
  变体选择器只有**平台**（All / iOS / macOS），没有外观；
* `actool` 对 `image-name-specializations`（字符串值与对象值都试过）**不把那
  张图编进产物** —— 只有基底那张进去；
* `ictool` 确实会评估特化（用 GUI 自己写出的 `opacity-specializations` 验证过：
  Default 亮度 190 → Dark 49），但无论怎么写，深色渲染始终用基底那张图。

**但同一个机制对 `Opacity` 是生效的** —— 于是"深色换图"可以用两个图层 + 各在
对方外观里把 `Opacity` 设成 0 来表达。这就是当前 `AppIcon.icon` 里的做法：

```json
"layers": [
  { "image-name": "Phecda-Light.png", "name": "Light",
    "opacity-specializations": [ { "appearance": "dark", "value": 0 } ] },
  { "image-name": "Phecda-Dark.png",  "name": "Dark",
    "opacity-specializations": [ { "appearance": "light", "value": 0 } ] }
]
```

两条**必须注意**的地方：

* **基底 `opacity` 保持默认（100%）**，只在特化里写 0。反过来写（基底 0 + 深色 1）
  不生效 —— 实测过：深色外观会变成"只剩底色"，深色稿根本不出来。
* 外观取值只有 `base` / `light` / `dark` / `tinted`；写 `clear` 会让整份文档**编译
  失败**。因此 `ClearDark` 这一档目前显示的是浅色稿（已知的小限制）。

六种渲染的实测（`Scripts/icon-preview.sh` 出的图，括号里是亮像素占比）：

| 外观 | 结果 |
|---|---|
| Default / TintedLight / ClearLight | 浅色稿（82%） |
| **Dark / TintedDark** | **黑底白标（8.4%，与深色稿原图的 8.5% 一致）** |
| ClearDark | 浅色稿（系统 Clear 档的限制，见上） |

### 为什么不能照搬 Mizar 的写法

Mizar（iOS/watchOS）确实是"appiconset + `luminosity: dark`"：

```json
{ "appearances": [ { "appearance": "luminosity", "value": "dark" } ],
  "filename": "icon-1024-dark.png", "idiom": "universal",
  "platform": "ios", "size": "1024x1024" }
```

它在 iOS 上有效（Mizar 的归档产物里 AppIcon 6 条，其中 **2 条 `UIAppearanceDark`**）。
Phecda 原来那份 appiconset 用的是**一模一样**的声明（10 条深色条目，`idiom: mac`），
在 macOS 上却被 `actool` 当成 `unassigned children` 丢掉 —— **差的是平台，不是写法**：
macOS 26 的图标外观走 `.icon`，appiconset 的深色槽位只存在于 iOS/watchOS。

### 改图标（Layer 层面）

素材在 `Sources/` 下，是**尺寸统一**的 1024² 导出图：

| 文件 | 用途 |
|---|---|
| `Sources/Phecda-Light-1024.png` | 浅色外观的图层图 |
| `Sources/Phecda-Dark-1024.png` | 深色外观的图层图 |

> 别用 `Sources/Phecda-Light.jpeg` / `Phecda-Dark.jpeg` 那两张设计原图：它们是
> 1019² 与 1747²，**尺寸不同**，在 `Layout` 100% 下会让两个图层差出 1.7 倍
> （踩过一次：深色图标看起来"变得很大"，就是拖了 1747² 那张进来）。

在 Icon Composer 里改：

1. `open Apps/Phecda/AppIcon.icon`；
2. 选中 `Light` 图层 → `Color` 段右侧的**外观**选择器选 `Dark` → `Opacity` 设 `0%`；
3. 选中 `Dark` 图层 → 外观选择器选 `Light` → `Opacity` 设 `0%`；
4. ⌘S。

（Icon Composer 保存时会**剪掉没被引用的素材**，所以图层图要从 `Sources/` 拖进去，
不要指望"先放进 `Assets/` 再引用"。）

### 改图标的验证

```bash
Scripts/icon-preview.sh && open Build/icon-preview   # 六种外观各长什么样，看 Dark 是不是黑底白标
python3 Scripts/gen-project.py                        # 提醒 Assets/ 里有没有没被引用的图
xcodebuild -project Phecda.xcodeproj -scheme Phecda \
  -configuration Debug -derivedDataPath Build/DerivedData build
```

产物层要看到这两样（`xcrun assetutil --info .../Assets.car`）：

* `AppIcon_Assets/Phecda-Light` 与 `AppIcon_Assets/Phecda-Dark` **两张都在**；
* AppIcon 至少有一条带 `Appearance`（深浅色/Tinted）。



### 三道防静默失败的守卫

* `Scripts/gen-project.py` 在生成前检查 `AppIcon.icon/icon.json` 存在、是合法
  JSON、图层引用的图真的在 `Assets/` 里 —— 不满足就直接生成失败。
* 同一个脚本还会**提醒** `Assets/` 里没被 `icon.json` 引用的图：没被引用就不会
  进包，所以"深色稿躺在 Assets 里但没人引用"意味着深色外观用的还是浅色稿 ——
  这一点在构建日志、测试和产物里都看不出来。提醒消失 = 指派成功了。
* `Scripts/check-submission.sh` 在归档产物里断言 `Assets.car` 的 AppIcon
  **至少有一条带外观变体** —— 深色变体丢了是静默的，这条断言是它唯一的报警器。

Mizar（iOS / watchOS）仍然走 appiconset，那边两条外观都验证在 `Assets.car` 里。
