<p align="center">
  <img src="assets/logo.png" width="180" alt="JMComic Logo" />
</p>

<h1 align="center">JMComic</h1>

<p align="center">
  原生 SwiftUI 漫画阅读器 · 本 fork 仅提供 macOS（Apple 芯片）安装包
</p>

<p align="center">
  <img alt="License" src="https://img.shields.io/badge/license-MIT-blue.svg" />
  <img alt="Swift" src="https://img.shields.io/badge/Swift-5.9-F05138.svg" />
  <img alt="macOS" src="https://img.shields.io/badge/macOS-14.0%2B-000000?logo=apple&logoColor=white" />
  <a href="https://github.com/Hovitesalyn-Luoe/jmcomic-app/releases"><img alt="Release" src="https://img.shields.io/github/v/release/Hovitesalyn-Luoe/jmcomic-app?include_prereleases" /></a>
  <a href="https://linux.do" title="linux.do · 新的理想型社区"><img alt="linux.do" src="assets/linuxdo-badge.svg" /></a>
</p>

## 本仓库是个人 fork

上游：[GuyCui/jmcomic-app](https://github.com/GuyCui/jmcomic-app)（MIT，见 [LICENSE](LICENSE)）。
本 fork 只做个人使用所需的修复与增强，构建产物**不含任何个人数据**；
现成安装包见 [Releases](https://github.com/Hovitesalyn-Luoe/jmcomic-app/releases)（macOS / Apple 芯片，ad-hoc 签名）。

**平台范围**：本 fork **只维护并提供 macOS 版**。仓库里的 iOS 工程（`jmcomic-ios/`）来自上游，
**未做适配与验证，也不提供 IPA**；下面的 iOS 章节与构建说明均为上游原有内容，仅供参考。

相对于上游的改动：

| 改动 | 说明 |
| --- | --- |
| **热门页修复** | 上游用"空关键词搜索"取热门，服务端已作废（恒定返回 `total:0` / `content:[]`），热门页因此永远空白；改为 `categories/filter?o=mv` |
| **作者可点击** | 详情页作者可点，跳到"该作者的所有作品"（JM 无作者实体，按名字搜索，与其它客户端一致） |
| **滚动位置记忆 + 回到顶部** | 每个页面滑到哪，切走再切回就回到哪（分类页只记右侧结果区）；工具栏新增「回到顶部」（在刷新左边）。纯 SwiftUI 实现：`scrollTargetLayout()` 放在懒加载容器、`scrollPosition` 放在 ScrollView |
| **分类页记住勾选** | 勾选写入本地，切回 / 重开立即还原并自动取回上次的结果（原先要等约 1 秒） |
| **软件更新检查** | 设置页「软件更新」：显示当前版本、手动检查、**默认开启的启动自动检查**；发现新版本弹窗，「前往下载」直达 Releases |
| **同步更稳（修界面冻死）** | git 改走系统代理，且不再在主线程上等待（旧版会整个界面冻住）；单条命令 15 秒超时。首次 `clone` 私有仓库补上认证头 |
| **凭证本地化** | Token / 同步密码 / 本地库密钥由钥匙串改为本地文件（0600），避免 ad-hoc 签名下每次重编都弹钥匙串 |
| **菜单栏汉化** | 增加 `zh-Hans.lproj` 与本地化声明，系统标准菜单（文件 / 编辑 / 显示 / 窗口 / 帮助）显示中文 |
| **⌘S 开关侧边栏** | 状态驱动（不依赖 AppKit 响应链），并记住展开状态 |
| **下载位置设置** | 设置页新增「下载」卡片：显示 / 更改保存路径、在访达中打开、恢复默认 |
| **界面小修** | 去掉「为你推荐」页重复出现的刷新按钮 |
| **构建脚本修复** | 产物路径改用 `swift build --show-bin-path`；增加 `RELEASE_TAG` 写入 Info.plist（供更新检查比对）；二进制如实记录编译所用 SDK |

安装包为 **ad-hoc 签名**：首次打开请右键 →「打开」，或到「系统设置 → 隐私与安全性」点「仍要打开」。
凭证保存在 `~/Library/Application Support/JMComic/secrets/`（仅当前用户可读）。

<p align="center">
  <a href="#-下载安装">📦 下载</a> ·
  <a href="#-功能">✨ 功能</a> ·
  <a href="#-上游接口仓库">🔗 上游</a> ·
  <a href="#-构建">🔨 构建</a> ·
  <a href="#-隐私与安全">🔒 隐私</a> ·
  <a href="#-免责声明">⚠️ 免责</a>
</p>

---

一个为个人使用而生的原生阅读器，用 SwiftUI + SwiftPM 从零搭建，**不依赖任何第三方库**。所有网络、加密、图片解码都用 Apple 原生 API 实现，启动快、体积小、行为可控。

包含两个独立端：

| 端 | 目录 | 说明 |
| --- | --- | --- |
| 🖥️ **macOS** | `jmcomic-swift/` | 完整桌面阅读器，SwiftPM 工程 |
| 📱 **iOS**（上游内容，本 fork 未适配与验证） | `jmcomic-ios/` | 独立 iPhone 应用，可与桌面端局域网同步 |

## 📦 下载安装

前往 [Releases](https://github.com/Hovitesalyn-Luoe/jmcomic-app/releases) 下载 `JMComic-*-macos-arm64.zip`，解压后得到：

```
JMComic.app      ← 拖入「应用程序」即可使用（macOS 14+ / Apple 芯片）
```

- **首次打开**：本包为 ad-hoc 签名 → 右键 →「打开」，或到「系统设置 → 隐私与安全性」点「仍要打开」。
- **iOS**：本 fork **不提供 iOS 包**，也未做适配与验证。上游提供 `jmcomic-ios/` 工程，
  如需自行尝试：用 Xcode 打开 `jmcomic-ios/jmcomic-ios.xcodeproj`，在 Signing & Capabilities
  选自己的 Team（免费 Apple ID 即可）后运行到真机（免费签名有效期 7 天）。

## ✨ 功能

### 🖥️ macOS 阅读器

- **阅读**：连续滚动 / 单页翻书、键盘翻页、双击放大、沉浸顶栏、跳页条、断点续读
- **浏览**：热门 / 最新 / 历史 / 最近浏览 / 收藏 / 分类（多选精准筛选）/ 为你推荐（本地画像）
- **本地**：收藏分组、整本下载（CBZ / 散图）、目录扫描导入、内容过滤（不感兴趣标签）
- **局域网**：手机扫码阅读、在线设备管理、设备信任开关（不信任设备只读）
- **安全**：AES 加密存储（本 fork 中密钥改存本地文件 `~/Library/Application Support/JMComic/secrets/`，权限 0600；上游为钥匙串）、一次性入场 token、密码限流、可选 HTTPS
- **同步**：GitHub 私有仓库加密备份（收藏 + 历史 + 进度），换机一条命令恢复

### 📱 iOS 应用（上游内容，本 fork 未适配与验证）

- 浏览 / 阅读 / 收藏 / 本地库，与 Mac 端功能对齐
- **桌面端同步**：扫描桌面端二维码配对，局域网内阅读桌面端已下载的漫画

## 🔗 上游接口仓库

本项目的接口加解密、图片解重组、域名轮换等机制参考自上游 Java API 库：

> **[JMComic-Api-Java](https://github.com/JUKOMU/JMComic-Api-Java)** — 获取 JMComic（禁漫天堂）数据的 Java API 库（MIT，© JUKOMU）

上游能力全面（漫画/下载/用户/评论/收藏/小说/创作者/签到/发现等），本项目用 **Swift** 从零重新实现其中的「浏览 / 阅读 / 收藏 / 同步」核心子集，并叠加原生 SwiftUI 图形界面。完整的上游能力对照表见 [docs/upstream.md](docs/upstream.md)。

## 🔨 构建

### macOS

```bash
cd jmcomic-swift
swift run -c release              # 直接运行
./build-app.sh --install          # 打包并安装到 /Applications
```

### iOS

Xcode 打开 `jmcomic-ios/jmcomic-ios.xcodeproj`，选自己的 Team 后运行到真机；或编译验收（模拟器）：

```bash
cd jmcomic-ios
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer bash build.sh
```

## 🧱 架构

```
jmcomic-swift/Sources/JMComic/
├── App.swift                入口 + 路由
├── Core/                    actor 并发核心
│   ├── JmClient.swift       域名轮换 + 签名请求 + 解密
│   ├── ImagePipeline.swift  ImageIO 解码 → CGImage 切块重排
│   ├── ImageStore.swift     内存 LRU + 磁盘缓存 + 请求合并
│   ├── CryptoStore.swift    AES 加密存储（本 fork 中密钥存本地文件）
│   ├── SyncStore.swift      GitHub 私有仓库加密同步
│   └── ...
└── UI/                      SwiftUI 视图
```

**关键设计**：actor 保证并发安全、零依赖、图片解重组不重编码、域名失败自动轮换、AES 密钥落本地且文件权限 0600。

> 📚 完整文档见 [docs/](docs/)：[上游对照](docs/upstream.md) · [架构设计](docs/architecture.md) · [接口文档](docs/api.md) · [开发指引](CLAUDE.md)

## 🔒 隐私与安全

- 历史 / 收藏 / 进度全部 AES 加密落盘；本 fork 中密钥存 `~/Library/Application Support/JMComic/secrets/`（上游为 macOS 钥匙串），文件权限 `0600`
- Web 访问三门槛：一次性 token → 短时凭证 → 密码会话（绑定 IP + 限流）
- 数据同步到自己的 GitHub 私有仓库，仓库里只有密文

## ⚠️ 免责声明

本项目仅用于个人技术学习与合法用途。请勿用于违反法律法规或平台规则的行为，使用者自行承担一切责任。

# 友情链接

[linux.do](https://linux.do)

## 📄 License

[MIT](LICENSE) © 2026 JUKOMU、yxxbc
