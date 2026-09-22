# MD3Music-iOS — Material Design 3 音乐播放器（iOS 移植版）

<div align="center">

[![Flutter](https://img.shields.io/badge/Flutter-3.47+-02569B?logo=flutter)](https://flutter.dev)
[![Platform](https://img.shields.io/badge/Platform-Android%20%7C%20iOS-green)]()
[![License](https://img.shields.io/badge/License-AGPL--3.0-blue)](LICENSE)

</div>

MD3Music-iOS 是 [MD3Music](https://github.com/zzyoxml/md3Music/) 的 **iOS 移植版**。原项目是一款基于酷狗音乐 API 的 Flutter 音乐播放器，采用 Material Design 3 设计规范，内置嵌入式 Rust API 服务器，无需外部服务器即可使用，支持手机/平板自适应、Apple Music 风格播放页与逐字歌词。本项目在其基础上完成了 **iOS 平台的完整移植**（同时在原 Android 功能全部保留的前提下双端维护），包括原生均衡器、音乐频谱、桌面小组件、锁屏歌词、画中画悬浮歌词、快捷菜单等。

> **项目关系**：所有核心功能与架构出自原作者仓库 [zzyoxml/md3Music](https://github.com/zzyoxml/md3Music/)，本项目仅负责 iOS 平台移植与双端同步，请优先关注原作者仓库获取上游更新。
> 本项目仅供学习，请勿用于商业用途，详情见[免责声明](DISCLAIMER.md)。

***

## ✨ 功能特性

- **在线音乐** — 搜索、每日推荐、排行榜、私人 FM、歌单/专辑/歌手/评论/MV、云盘、听书、场景音乐、频道、刷刷短视频
- **本地音乐** — 文件夹浏览、内嵌封面与歌词、本地收藏、音质标签、多维度排序
- **播放体验** — 多音质选择（标准/高质/无损/Hi-Res）、USB 独占输出、均衡器、DLNA 投屏、睡眠定时、倍速、进度记忆、画中画
- **歌词** — Apple Music 风格逐字歌词（KRC/LRC），支持翻译/罗马音、辉光、模糊、动态取色，以及桌面/锁屏/蓝牙歌词与 SuperLyric 推送
- **用户中心** — VIP 双签到、多账号管理、听歌等级/排行/识曲、收藏与播放历史、桌面小组件
- **个性化** — MD3/AM 双风格、主题色与动态取色、深色模式、全局背景图、桌面歌词、主页 Tab 自定义、设置搜索

### 📱 iOS 移植内容

- **嵌入式 Rust 服务器（静态链接）** — Rust 服务器以静态库 `libkugou_server.a` 形式链接进 App（`DynamicLibrary.process()`），与 Android 的 `.so` 动态库方案对应
- **原生均衡器（5 段）** — 基于 `MTAudioProcessingTap`（AVAudioMix）实现，5 段 60/230/910/3600/14000 Hz、±15 dB，与 Android 端听感一致；输出硬限幅防爆音
- **真实音乐频谱** — EQ 前采样左声道 PCM，1024 点 FFT、40 频段，经 MethodChannel 与 Android 同协议驱动频谱 UI
- **桌面小组件（WidgetKit）** — 小号/中号小组件，播放状态与封面经 App Group 同步，秒级进度自推进；iOS 17+ 按钮走 AppIntent，iOS 15/16 经 URL Scheme 携带命令回跳
- **锁屏 / 控制中心** — Now Playing 信息与远程控制（`MPNowPlayingInfoCenter` + `MPRemoteCommandCenter`），封面/进度/播放状态完整同步
- **画中画悬浮歌词** — VideoCall 式 `AVPictureInPictureController`（`ContentSource`），300×22pt 单行细条悬浮歌词，无系统控件
- **音频焦点** — `AVAudioSession` 中断通知对齐 Android Media3 焦点协议（LOSS/GAIN/TRANSIENT），被其他 App 抢占时应用内同步暂停
- **长按快捷菜单** — quick_actions 动态注册（跟随设置页「桌面快捷方式」配置），冷启动/热路径均可路由到对应页面
- **免签侧载兼容** — 运行时经私有 API 解析签名中的实际 App Group（兼容 isideload 等免费签名工具改写的 group 标识）
- **播放自愈** — 暂停后锁屏挂起导致的播放通道失效（-1004）自动重建播放器实例；本地服务器停摆自检重启

***

## 🏗️ 架构说明

### 本地架构

```
┌───────────────────────────────────────────────────────────────┐
│                       MD3Music App                             │
│   ┌───────────────────────┐      ┌─────────────────────────┐    │
│   │    Flutter UI (Dart)  │      │  嵌入式 Rust API 服务器 │    │
│   │                       │      │     (127.0.0.1)         │    │
│   └───────────┬───────────┘      └───────────┬─────────────┘    │
│               │              JNI / FFI       │                  │
│               │        Android: libkugou_server.so (动态库)     │
│               │        iOS:     libkugou_server.a (静态链接)    │
│               └─────────────────┬────────────┘                  │
│                                 ▼                               │
│              ┌──────────────────────────────────┐               │
│              │         本地数据 / 缓存            │               │
│              └──────────────────────────────────┘               │
└───────────────────────────────────────────────────────────────┘
```

### 核心特点

- **嵌入式 Rust 服务器** — App 启动时启动本地 tiny\_http 服务器（`127.0.0.1`），所有酷狗 API 请求在本地处理；Android 经 JNI 加载 `libkugou_server.so`，iOS 静态链接 `libkugou_server.a` 经 FFI 启动
- **高性能低资源** — Rust 实现取代旧 Node.js 方案，内存占用更低，启动更快
- **无需外部服务器** — 用户无需自行搭建 API 服务器
- **多架构支持** — Android 支持 armeabi-v7a（32 位）、arm64-v8a（64 位）、x86、x86\_64（模拟器）；iOS 支持 arm64 真机
- **本地投屏支持** — 内置局域网 HTTP 服务器（支持 Range 请求），本地音乐也能投屏到 DLNA 设备

***

## 🔄 CI/CD

项目已配置 GitHub Actions（推送到 `main` 分支自动触发）：

- **Android APK**（ci.yml）— 自动构建 arm64-v8a / armeabi-v7a / x86\_64 产物
- **iOS 未签名包**（ios-build.yml）— macOS Runner（Xcode 26）构建未签名 ipa，供侧载工具（如 isideload / 云端侧载）签名安装
- **Release**（main.yml）— 推送 `v*` 标签自动创建 GitHub Release 并上传产物，自动递增 versionCode 并生成 Changelog
- 手动触发（workflow\_dispatch）支持重新构建指定版本

***

## 📷 界面预览

### 手机 · Material Design 3

<p align="center">
  <img src="img/phone/md3/Screenshot_2026-08-31-23-35-42-974_com.md3music.md3music-edit.png" width="220" alt="手机 MD3 界面 1" />
  <img src="img/phone/md3/Screenshot_2026-08-31-23-35-52-228_com.md3music.md3music-edit.png" width="220" alt="手机 MD3 界面 2" />
  <img src="img/phone/md3/Screenshot_2026-08-31-23-36-24-517_com.md3music.md3music-edit.png" width="220" alt="手机 MD3 界面 3" />
</p>

### 手机 · Apple Music 风格

<p align="center">
  <img src="img/phone/applemusic/Screenshot_2026-08-31-23-22-42-956_com.md3music.md3music-edit.png" width="220" alt="手机 Apple Music 风格 1" />
  <img src="img/phone/applemusic/Screenshot_2026-08-31-23-26-45-407_com.md3music.md3music-edit.png" width="220" alt="手机 Apple Music 风格 2" />
  <img src="img/phone/applemusic/Screenshot_2026-08-31-23-27-17-235_com.md3music.md3music-edit.png" width="220" alt="手机 Apple Music 风格 3" />
</p>

### 手机 · 更多界面(夜间和横屏)

<p align="center">
  <img src="img/phone/other/Screenshot_2026-08-31-23-47-10-817_com.md3music.md3music-edit.png" width="220" alt="手机更多界面 1" />
  <img src="img/phone/other/Screenshot_2026-08-31-23-45-31-324_com.md3music.md3music-edit.png" width="220" alt="手机更多界面 2" />
  <img src="img/phone/other/Screenshot_2026-08-31-23-45-14-931_com.md3music.md3music-edit.png" width="220" alt="手机更多界面 3" />
</p>

<p align="center">
  <img src="img/phone/other/Screenshot_2026-08-31-23-44-24-306_com.md3music.md3music.jpg" width="500" alt="手机更多界面 4" />
</p>

### 平板 · Material Design 3

<p align="center">
  <img src="img/pad/md3/mmexport1788192053922.jpg" width="500" alt="平板 MD3 界面 1" />
  <img src="img/pad/md3/mmexport1788192055275.jpg" width="500" alt="平板 MD3 界面 2" />
</p>

### 平板 · Apple Music 风格(横屏 和 zen沉浸模式)

<p align="center">
  <img src="img/pad/applemusic/mmexport1788192056938.jpg" width="500" alt="平板 Apple Music 风格 1" />
  <img src="img/pad/applemusic/mmexport1788192058255.jpg" width="500" alt="平板 Apple Music 风格 2" />
</p>

***

## 🚀 快速开始

### 前置要求

**通用**

- **Flutter SDK** 3.47.0 或更高版本
- **Rust** 1.70+（用于构建嵌入式 API 服务器，若使用已提交的产物可跳过）

**Android 额外要求**

- **Android Studio** / VS Code
- **Android NDK** 28（用于 Rust 交叉编译）

**iOS 额外要求**

- **macOS** + **Xcode 26** 或更高版本（iOS 依赖链要求）
- Rust 目标 `aarch64-apple-ios`
- iOS 构建产物 `libkugou_server.a`（放置于 `ios/rustlib/`）

### 1. 克隆项目

```bash
git clone https://github.com/EPXiaohua/MD3Music-iOS.git
cd MD3Music-iOS
```

### 2. 安装 Flutter 依赖

```bash
flutter pub get
```

### 3. 构建 Rust 服务器（可选）

Rust 服务器产物已提交进 Git 仓库（Android 为 `libkugou_server.so`，iOS 为 `ios/rustlib/libkugou_server.a`），通常无需重新编译。仅当你修改了 `kugou_api_server/rust/src/` 下的代码时才需要重建：

```bash
cd kugou_api_server/rust

# 主机编译验证
cargo build --release
cargo test        # 本地冒烟测试

# Android 交叉编译（4 个 ABI，需要 NDK）
./build_android.sh

# iOS 交叉编译（arm64，需要 rustup target add aarch64-apple-ios）
./build_ios.sh
```

### 4. 运行应用（调试模式）

```bash
# Android：连接设备后执行
flutter run

# iOS：连接 iPhone 后执行（或 Xcode 打开 ios/Runner.xcworkspace 运行）
flutter run --release
```

### 5. 构建发布包

```bash
# Android：构建三个架构的 APK（分拆包）
flutter build apk --release --split-per-abi
# 输出位置：
# build/app/outputs/flutter-apk/app-armeabi-v7a-release.apk  (32 位)
# build/app/outputs/flutter-apk/app-arm64-v8a-release.apk   (64 位)
# build/app/outputs/flutter-apk/app-x86_64-release.apk      (模拟器)

# iOS：构建未签名 ipa（供侧载工具签名，需开发者证书或免费 Apple ID）
flutter build ipa --release --no-codesign
```

> **iOS 免签侧载**：可使用 [isideload](https://github.com/nab138/isideload) 等免费签名工具安装未签名 ipa。App 已内置运行时 App Group 自动解析（兼容签名工具改写 group 标识），无需修改工程配置。

***

## 📁 项目结构

```
MD3Music-iOS/
├── lib/                        # Flutter 应用代码（双端共享）
│   ├── main.dart               # 应用入口
│   ├── app.dart                # 主应用组件
│   ├── core/                   # 核心模块
│   │   ├── layout/             # 响应式布局
│   │   ├── services/           # 平台服务（音频/USB 独占/均衡器/DLNA 投屏/频谱/桌面歌词/词幕/小组件）
│   │   ├── theme/              # 主题配置
│   │   └── utils/              # 工具类
│   ├── data/                   # 数据层
│   │   ├── models/             # 数据模型
│   │   └── repositories/       # 数据仓库（设置/收藏/历史）
│   ├── modules/                # 功能模块
│   │   ├── home/               # 主页（每日推荐等）
│   │   ├── launchpad/          # LaunchPad 导航
│   │   ├── discover/           # 发现页
│   │   ├── charts/             # 排行榜
│   │   ├── coverflow/          # 封面流（CoverFlow 3D）
│   │   ├── player/             # 播放器（含评论视图/MV 播放）
│   │   ├── playlist/           # 歌单详情
│   │   ├── search/             # 搜索
│   │   ├── album/              # 专辑详情
│   │   ├── artist/             # 歌手详情
│   │   ├── personal_fm/        # 私人 FM
│   │   ├── ip/                 # 编辑精选
│   │   ├── audiobook/          # 听书
│   │   ├── scene/              # 场景音乐
│   │   ├── channel/            # 频道
│   │   ├── brush/              # 刷刷（竖屏视频流）
│   │   ├── user/               # 用户中心（签到/收藏/历史/听歌排行）
│   │   ├── library/            # 音乐库（本地音乐/云盘）
│   │   ├── settings/           # 设置（含均衡器）
│   │   ├── login/              # 登录
│   │   ├── onboarding/         # 新手引导
│   │   └── recognition/        # 听歌识曲
│   ├── providers/              # 状态管理
│   ├── services/               # 服务层（本地 API 客户端 / 服务器启动）
│   └── widgets/                # 公共组件
│       └── apple_lyrics/       # Apple Music 风格歌词
├── kugou_api_server/           # 嵌入式 Rust API 服务器
│   ├── rust/                   # Rust crate（tiny_http + ureq）
│   │   ├── src/
│   │   │   ├── lib.rs          # FFI/JNI 导出符号
│   │   │   ├── server.rs       # HTTP 服务器：路由分发、CORS、缓存
│   │   │   ├── modules/        # 160+ 个 API 模块
│   │   │   ├── crypto.rs       # MD5/SHA1/AES/RSA 加密
│   │   │   ├── request.rs      # 上游转发（ureq）
│   │   │   └── device.rs       # 设备信息持久化
│   │   ├── tests/smoke.rs      # 本地冒烟测试
│   │   ├── build_android.sh    # Android 交叉编译脚本
│   │   └── Cargo.toml
├── ios/                        # iOS 平台（本仓库移植重点）
│   ├── Runner/                 # 主 App
│   │   ├── AppDelegate.swift   # 应用入口 + 歌词 PiP 管理（LyricsPipManager）+ 字体/背景选择
│   │   ├── SceneDelegate.swift # 场景生命周期（小组件 URL 回跳 / quick_actions）
│   │   ├── AudioEqualizer.swift# 5 段均衡器（MTAudioProcessingTap）+ 频谱 FFT 采样
│   │   ├── WidgetSync.swift    # 桌面小组件状态同步 + App Group 自动解析
│   │   └── Info.plist          # URL Scheme / 后台音频 / 本地网络权限
│   ├── MD3Widget/              # 桌面小组件 extension（WidgetKit）
│   ├── rustlib/                # libkugou_server.a（Rust 静态库）
│   └── Runner.xcodeproj        # Xcode 工程（含 app-extension target）
├── third_party/just_audio/     # just_audio fork（iOS 均衡器引导/音频中断转发）
├── assets/                     # 资源文件
│   ├── images/                 # 图片资源
│   └── fonts/                  # 字体文件
├── android/                    # Android 平台配置
│   └── app/src/main/
│       ├── cpp/                # USB 独占输出 C++ 驱动（CMake）
│       ├── kotlin/             # KugouApiService（启动本地服务器）/ MainActivity
│       └── jniLibs/            # libkugou_server.so（四个架构）
└── pubspec.yaml                # Flutter 配置
```

***

## 🛠️ 技术栈

| 类别           | 技术                                                               |
| ------------ | ---------------------------------------------------------------- |
| **UI 框架**    | Flutter 3.47+                                                    |
| **状态管理**     | Provider                                                         |
| **动效**       | m3e\_core（M3 Expressive Motion）                                  |
| **音频播放**     | just\_audio（iOS 使用 fork 版）+ just\_audio\_background            |
| **音频焦点**     | audio\_session（Android）/ AVAudioSession（iOS）                    |
| **网络请求**     | Dio                                                              |
| **本地存储**     | SharedPreferences + SQLite                                       |
| **图片缓存**     | cached\_network\_image                                           |
| **嵌入式服务器**   | Rust（tiny\_http + ureq）                                          |
| **加密**       | rsa / aes / md-5 / sha1 / sha2                                   |
| **元数据读写**    | audio\_metadata\_reader + JAudioTagger (MP3/FLAC/M4A)            |
| **DLNA 投屏**  | dlna\_dart                                                       |
| **MV 播放**    | video\_player + chewie                                           |
| **USB 独占输出** | 原生 JNI + CMake C++（usbdevfs，Android）                           |
| **取色**       | palette\_generator + dynamic\_color + material\_color\_utilities |
| **桌面歌词**     | Lyricon Provider（Android）/ AVPictureInPictureController（iOS）  |
| **听歌识曲**     | record（录音）+ Rust PCM 预处理                                         |
| **原生通知**     | fluttertoast（Toast）                                              |
| **文件/权限**    | permission\_handler + path\_provider                             |
| **桌面快捷方式**   | quick\_actions                                                   |
| **音频均衡器**    | just\_audio 平台均衡器（Android）/ MTAudioProcessingTap（iOS）        |
| **桌面小组件**    | AppWidget（Android）/ WidgetKit + App Group（iOS）              |
| **音乐源**      | 酷狗音乐 API                                                         |

***

## ⚙️ 配置说明

### 嵌入式服务器

应用启动时自动启动本地 Rust 服务器，监听 `127.0.0.1` 的**随机端口**（10000\~60000，被占用自动更换），实际端口由服务器启动后回传给应用，无需任何配置。Android 与 iOS 共用同一套 Rust 代码，仅加载方式不同（动态库 JNI / 静态库 FFI）。

### 音质设置

| 音质     | 格式       | 比特率          |
| ------ | -------- | ------------ |
| 标准     | MP3      | 128 kbps     |
| 高质     | MP3      | 320 kbps     |
| 无损     | FLAC     | \~1000 kbps  |
| Hi-Res | FLAC/MKV | \~2000+ kbps |

***

## 🛠️ 开发说明

### 修改嵌入式服务器代码

1. 修改 `kugou_api_server/rust/src/` 目录下的 Rust 源代码
2. 主机编译验证：
   ```bash
   cd kugou_api_server/rust
   cargo build --release
   cargo test        # 运行测试
   cargo clippy      # 静态检查
   ```
3. 移动端交叉编译：Android 执行 `./build_android.sh`；iOS 执行 `./build_ios.sh`（产物放 `ios/rustlib/`）
4. 重新编译 App

### 添加新 API 模块

在 `kugou_api_server/rust/src/modules/` 下新建 `.rs` 文件，实现对应的 API 端点处理函数，然后在 `server.rs` 中注册路由即可。

### iOS 原生开发注意

- 新增 Swift 文件需手动加入 Xcode 工程（`Runner` 或 `MD3Widget` target）
- iOS 音频中断通知、均衡器引导依赖 `third_party/just_audio` fork（darwin 侧改动），勿随意升级该依赖
- 桌面小组件的 App Group 采用运行时解析，签名环境变化无需改代码

***

## 🔧 常见问题

**Q: 应用启动后无法搜索或播放音乐？**

A: 检查日志确认 Rust 服务器是否成功启动。Android 在 Logcat 中搜索 `KugouApiService`；iOS 连接 Xcode 查看控制台，或使用应用内「诊断日志」导出。

**Q: 登录功能无法使用？**

A: 登录/注册/验证码已全部本地化：由嵌入式 Rust 服务器直连酷狗官方接口处理，不再依赖第三方云端。请确保设备可正常联网，并确认本地服务器已成功启动。

**Q: iOS 免签安装后小组件不显示数据？**

A: 免签工具会改写 App Group 标识，App 已内置运行时解析（读取签名 entitlements 中的实际 group），正常无需任何配置；若仍异常，尝试移除小组件后重新添加。

**Q: 如何修改 API 服务器代码？**

A: 修改 `kugou_api_server/rust/src/` 下的 Rust 代码，运行 `cargo build --release` 编译验证，Android 侧执行 `./build_android.sh` 交叉编译、iOS 侧执行 `./build_ios.sh`，再重新编译 App。

**Q: 为什么 Rust 服务器需要 NDK / iOS 交叉编译工具链？**

A: Rust 的 TLS 依赖（`ring` crate）需要交叉编译为各平台产物：Android 为 `.so`（NDK 提供 clang 工具链），iOS 为 `.a` 静态库（`rustup target add aarch64-apple-ios`）。

***

## 🤝 致谢

### 上游项目

- [zzyoxml/md3Music](https://github.com/zzyoxml/md3Music/) — 本项目的上游，MD3Music 全部核心功能出自原作者与以下贡献者

### 上游致谢（原项目）

- [EchoMusic](https://github.com/hoowhoami/EchoMusic) — UI 设计和架构参考
- [apple-music-like-lyrics](https://github.com/amll-dev/applemusic-like-lyrics) — Apple Music 风格逐字歌词渲染参考
- [Lyricon](https://github.com/tomakino/lyricon) — 桌面歌词 Provider（词幕 / 悬浮歌词）
- [SuperLyric](https://github.com/HChenX/SuperLyric) — 系统级实时歌词（Lyricon/SuperLyric 协议）
- [LyricInfo](https://github.com/limczhh/LyricInfo) — 蓝牙歌词（AVRCP/LyricInfo 歌词推送参考）
- [Lyrico](https://github.com/Replica0110/Lyrico) — 本地音乐标签编辑 / Lyrico 外部编辑协作
- [ColorOS-Live-Lyrics-Bridge](https://github.com/Andrea-lyz/ColorOS-Live-Lyrics-Bridge) — ColorOS 息屏歌词桥接（lyricInfo 开放协议参考）
- [Reorderable](https://github.com/Calvin-LL/Reorderable) — 播放列表面板长按拖拽排序
- [MaterialKolor](https://github.com/jordond/MaterialKolor) — 莫奈取色 / Material Design 3 动态配色
- [KuGouMusicApi](https://github.com/MakcRe/KuGouMusicApi) — API 代理服务
- [tiny\_http](https://github.com/tiny-http/tiny-http) — Rust HTTP 服务器
- [ureq](https://github.com/algesten/ureq) — Rust HTTP 客户端
- [JAudioTagger](https://www.jthink.net/jaudiotagger/) — 音频元数据读写
- [decent-player](https://github.com/Ma145/decent-player) — USB 独占音频输出（DAC 独占驱动 C++/Kotlin 移植自其 `decent-usb-audio-driver`）

### iOS 移植使用

- [nab138/isideload](https://github.com/nab138/iloader) — IPA签名侧载工具（App Group 兼容逻辑参考）

***

## 👥 贡献者

感谢上游项目所有为 MD3Music 做出贡献的朋友：

<p align="center">
  <a href="https://github.com/zzyoxml"><img src="https://avatars.githubusercontent.com/u/137420502?v=4&s=80" width="80" height="80" alt="zzyoxml" title="zzyoxml" /></a>
  <a href="https://github.com/Little-White3110"><img src="https://avatars.githubusercontent.com/u/53994162?v=4&s=80" width="80" height="80" alt="Little-White3110" title="Little-White3110" /></a>
  <a href="https://github.com/Saul-Soul"><img src="https://avatars.githubusercontent.com/u/155223948?v=4&s=80" width="80" height="80" alt="Saul-Soul" title="Saul-Soul" /></a>
  <a href="https://github.com/LyonHyrik"><img src="https://avatars.githubusercontent.com/u/309263464?v=4&s=80" width="80" height="80" alt="LyonHyrik" title="LyonHyrik" /></a>
  <a href="https://github.com/Andrea-lyz"><img src="https://avatars.githubusercontent.com/u/52863141?v=4&s=80" width="80" height="80" alt="Andrea-lyz" title="Andrea-lyz" /></a>
  <a href="https://github.com/7tattoo"><img src="https://avatars.githubusercontent.com/u/122350933?v=4&s=80" width="80" height="80" alt="7tattoo" title="7tattoo" /></a>
    <a href="https://github.com/sdawhk"><img src="https://avatars.githubusercontent.com/u/147570195?v=4" width="80" height="80" alt="7tattoo" title="7tattoo" /></a>
</p>

***

## 📄 许可证

本项目沿用上游的 [GNU AGPL-3.0](LICENSE) 许可证。

***

**Based on [MD3Music](https://github.com/zzyoxml/md3Music/) · iOS port maintained by [EPXiaohua](https://github.com/EPXiaohua)**
