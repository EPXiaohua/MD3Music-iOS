## 本版亮点

- **iOS 开放文件系统**：开启文件共享（File Sharing）与原地打开——「文件」App 中出现 MD3Music 目录，可直接浏览应用内文件、从其它 App 投递音频文件进来，电脑 Finder 也能直接拖入
- **iOS 本地音乐改为文件夹授权**：移除「导入」，改用系统「文件」App 授权文件夹——授权后书签持久化（冷启动自动恢复访问）、原位扫描原位播放不占双份空间；界面与 Android 同一套（曲目/专辑/艺术家/文件夹/收藏，扫描菜单、排除文件夹一致），未扫描时空状态按钮为「授权文件夹」，加号菜单「扫描音乐」与 Android 一致为纯重扫
- **iOS 均衡器体验修复**：调节滑杆不再有「咔哒」噪声（系数改为逐样本平滑逼近，不复位滤波器状态）；修复调节后效果时有时无、需要反复调的问题（回归稳定的 activeBands 架构）
- **iOS 画中画悬浮歌词修复**：背景不再闪烁、歌词不再有残影、边缘不再有黑色羽化/黑边（高斯模糊改为外扩渲染裁中心区，杜绝边缘污染与半透明带）

## 其它

- README 构建说明澄清：Rust 服务器为后期引入组件，Android 产物已入库、**iOS 产物（libkugou_server.a）未入库，本地构建 iOS 前必须先执行 `build_ios.sh` 交叉编译**
- 签名与小组件兼容说明澄清：使用免费 Apple ID 签名（7 天）；App Group 兼容**目前仅支持 [iloader](https://github.com/nab138/iloader)**，AltStore 等其他工具签名后主应用可用但小组件不刷新

未签名 IPA：下载后自行签名安装（推荐 [iloader](https://github.com/nab138/iloader)，免费 Apple ID 签名即可）。

- `MD3Music-unsigned.ipa`：标准版（无 3D 封面，推荐）
- `MD3Music-3D-unsigned.ipa`：含 3D 封面支持版（内置 Depth Anything V2 深度模型与 MI-GAN 修补模型，设置中开启 3D 封面即可；生成失败时自动回退平面封面，包体约 +40MB）

> 小组件提示：请使用 iloader 签名。AltStore/SideStore、爱思助手等其它工具签名后，主应用一切正常，仅桌面小组件无法收到播放状态。

仅供学习交流，请勿用于商业用途！详见[免责声明](https://github.com/EPXiaohua/MD3Music-iOS/blob/main/DISCLAIMER.md)。如条件允许请支持原作者项目：[zzyoxml/md3Music](https://github.com/zzyoxml/md3Music/)。
