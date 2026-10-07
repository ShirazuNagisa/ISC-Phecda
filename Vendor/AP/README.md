# Vendor/AP —— 闭源推送库（libiscap）

这个目录是 `libiscap.dylib` 的落点，形态与 `Vendor/ISC` 一致：**包体 + 版本化
C ABI**，界面侧不 import 任何 Go 包。

## 为什么这里的二进制**不进 git**

内核库（`Vendor/ISC/libisc.dylib`）进 git，因为它由开源仓库 ISC-Core 编出来，
谁都能自己重新编一份。**推送库不一样**：ISC-Ap 是闭源的，它的私钥（`.p8`）一旦
公开，拿到的人就能以本应用的名义给所有用户推通知。

所以这里只有两样东西进 git：

| 文件 | 进 git | 为什么 |
|---|---|---|
| `module.modulemap` | ✅ | 只是 ABI 的形状，没有库时也发现不了这个 module |
| `README.md` | ✅ | 这一页 |
| `libiscap.h` | ❌ | 闭源库的一部分（cgo 生成） |
| `libiscap.dylib` | ❌ | 闭源库本体 |
| `SHA256SUMS` | ❌ | 跟着上面两个一起由 vendor 脚本产出 |
| `libiscap.xcconfig` | ❌ | 由 vendor 脚本产出；**它的存在与否决定 Release 链不链推送库** |

`module.modulemap` 单独进 git 不会让缺少库的构建"看见"这个 module —— 编译器
要能找到它得先有 `-I Vendor/AP`，而那条路径来自 `libiscap.xcconfig`，只在
vendor 过之后才存在。见 `Configs/Release.xcconfig`。

## 放进来

```bash
Scripts/vendor-ap.sh                    # 从 ../ISC-Ap 取（必要时先构建）
Scripts/vendor-ap.sh --build            # 先跑 ISC-Ap 的 build.sh 再取
ISC_AP_DIR=/path/to/ISC-Ap Scripts/vendor-ap.sh
```

脚本会拷 `libiscap.dylib` / `libiscap.h` / `SHA256SUMS`，校验摘要，并写出
`libiscap.xcconfig`。**校验不过就停**：链接一份与记录不符的库，等于把一个
ABI/行为不明的二进制塞进发行版。

## 拿走

```bash
rm -f Vendor/AP/libiscap.* Vendor/AP/SHA256SUMS
```

删掉之后重新 `python3 Scripts/gen-project.py` 不是必须的 —— 工程文件里没有
任何指向这个目录的静态引用，链接设置由 `libiscap.xcconfig` 可选地提供。
Release 会静默退化成"没有推送能力"的构建，与从 GitHub 拿源码自编译的人看到的
完全一样。
