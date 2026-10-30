import 'dart:io';

import 'package:flutter/foundation.dart';

import 'build_flags.dart';

/// 平台能力门控：区分「Android 专属」与「桌面端也有」的 UI 入口。
///
/// **为什么不用 `kTvBuild`**（`lib/core/build_flags.dart`）：那组是编译期 const
/// （`--dart-define`），AOT 可树摇；本文件判断的是**运行时**平台，
/// 同一份 Windows 包里既要走桌面分支、又要能识别 Android 分支，
/// 因此必须是普通 getter。
///
/// **为什么不直接散落 `Platform.isAndroid`**：Android 专属入口有 20+ 处，
/// 散落后每新增一处都要重新判断"这个功能在桌面端行不行"。集中到这里后：
/// - 新增平台只需改这一个文件；
/// - 搜索 `supportsXxx` 就能列出全部平台相关入口，不会漏。
///
/// 用 `defaultTargetPlatform` 而非 `Platform.isAndroid`：Web 编译期
/// `dart:io` 不可用，`Platform.*` 会抛 UnsupportedError。
bool get isAndroidPlatform {
  if (kIsWeb) return false;
  if (Platform.isAndroid) return true;
  return defaultTargetPlatform == TargetPlatform.android;
}

/// 当前是否桌面端（Windows / macOS / Linux）。用于"桌面端额外能力"的
/// 正向判断（例如 Windows 才有原生消息框兜底）。
bool get isDesktopPlatform {
  if (kIsWeb) return false;
  if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) return true;
  return defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.linux;
}

/// 当前是否 Windows 桌面 —— 键鼠快捷键与窗口原生能力的唯一门控源。
///
/// **为什么不复用 [isDesktopPlatform]**：桌面能力里有两拨 —— 「mac/Linux 也成立」
/// 的（原生消息框兜底）和「只有本仓库的 Windows runner 实现了」的（无边框全屏、
/// F11、空格/F/Esc/鼠标侧键）。后者混进 `isDesktopPlatform` 会在 mac/linux 上
/// 留下按了没反应的死键位。
///
/// 口径用 `defaultTargetPlatform`，不用 `Platform.isWindows`：后者在 Windows 宿主
/// 上跑 `flutter test` 同样为 true，会把宿主平台泄漏进本该跑 Android 语义的测试
/// （`core/utils/app_toast.dart`、`WindowsFullscreen.supported` 同一教训）。
bool get isWindowsDesktop {
  if (kIsWeb) return false;
  return defaultTargetPlatform == TargetPlatform.windows;
}

/// 当前是否 iOS。用于「Android 与 iOS 都支持、仅桌面端不支持」的入口：
/// 本移植版在 iOS 侧有等价实现（软件 EQ 走 AVPlayer MTAudioProcessingTap、
/// 识曲走麦克风 PiP 链路、频谱走 AVAudioEngine、快捷方式走 UIApplication
/// shortcutItems），故这些入口必须对 iOS 可见，只对桌面端隐藏。
bool get isIOSPlatform {
  if (kIsWeb) return false;
  if (Platform.isIOS) return true;
  return defaultTargetPlatform == TargetPlatform.iOS;
}

/// 是否移动端（Android 或 iOS）。用于「移动端可用、桌面端无等价实现」的入口。
bool get isMobilePlatform => isAndroidPlatform || isIOSPlatform;

/// ---- Android 专属功能入口 ----
///
/// 每一项对应设置页里一个只在 Android 上成立的入口。桌面端必须隐藏，
/// 否则用户会点进一个永远不生效的页面（历史上已多次出现：
/// 点"USB 独占"却提示"未检测到 USB 音频设备"，完全是死路）。

/// USB 独占输出（Android 走 UAC1 DAC 直写 usbdevfs；iOS 无原生独占，
/// 但页面内已按平台降级为文件头解析的设备/格式状态展示）。
///
/// **TV 构建同样视为不支持**：tv flavor 置 `FEATURE_TV=true`，既不编译 USB 独占
/// C++ 驱动，也在 `MainActivity.registerPlaybackPlugins` 里跳过
/// `UsbAudioPlugin` / `DirectPcmPlugin` 注册（见 android/app/build.gradle.kts）。
/// 若只判平台，TV 会露出一个点不动的「USB 独占」分类与歌曲信息页死区块。
/// `kTvBuild` 是 const，TV 包内本表达式可被树摇折叠。
bool get supportsUsbExclusive => isMobilePlatform && !kTvBuild;

/// 听歌识曲（Android 走 `MediaSession`/麦克风链路；iOS 走麦克风采集 +
/// PiP 悬浮窗识别链路 `SongRecognitionPipManager`）。
bool get supportsSongRecognition => isMobilePlatform;

/// 预测性手势（横滑切歌 / 长按识别等，依赖 Android 系统的
/// `MotionEvent` 手势与振动反馈配合）。
bool get supportsPredictiveGesture => isAndroidPlatform;

/// 音乐频谱：Android 走 PCM 截取 / Visualizer 兜底，Windows 走 WASAPI 环回采集。
///
/// 两端共用同一条通道协议（`onFft` 40 段归一化幅值），差异只在原生数据源：
/// - Android：`SpectrumPlugin` 从 AudioSink 截 PCM，或挂 `Visualizer`；
/// - Windows：runner 的 `SpectrumCapture` 环回本进程音频（Win10 老版本回落到
///   系统混音）后做同款 1024 点 FFT。
/// - iOS：走 EQ tap 的 PCM 截取 FFT（`AudioEqualizer.spectrumFeed`）。
bool get supportsMusicSpectrum =>
    isAndroidPlatform || isWindowsDesktop || isIOSPlatform;

/// 震动反馈（交互震动 / 音乐节奏震动）。上游 6.0.0 新增项，原版仅 Android；
/// 本移植版 iOS 侧已接入等价实现（交互触感走 `UIFeedbackGenerator`、音乐节奏震动走
/// `CoreHaptics` 跟鼓点，见 `ios/Runner/HapticsPlugin.swift`），故对 iOS 一并开放。
bool get supportsHaptics => isMobilePlatform;

/// 桌面快捷方式（Android 走 `quick_actions_android`；iOS 走
/// `UIApplication.shortcutItems`，由 `ShortcutConfigProvider` 统一配置）。
bool get supportsDesktopShortcut => isMobilePlatform;

/// 系统音效链（均衡器 / 音效库 / 音量均衡 / 响度归一）。
///
/// 根���在 `EqualizerService`：它靠 `AudioSession` + `androidAudioSessionIds`
/// 绑定原生 `android.media.audiofx.Equalizer`。桌面端**没有任何等价实现**，
/// `tryBind()` 在非 Android 直接 `return false`。
///
/// ⚠️ 危险之处：**它不会报错**。`setEnabled(true)` 照样返回成功、
/// 持久化也照样写入，但 `tryBind()` 早已return false ⇒ 没有任何音效被挂载。
/// 用户看到"已开启"却听不出变化，是典型的假成功。必须隐藏入口。
///
/// iOS：同一服务走**软件 EQ**（`AVPlayer` + `MTAudioProcessingTap`，见
/// `ios/Runner/AudioEqualizer.swift`），绑定伪会话 id=0，功能等价。
bool get supportsSystemAudioEffects => isMobilePlatform;

/// 硬件解码播放（系统 audio offload 直通）。
///
/// 依赖 Media3 audio offload + API29（`Build.VERSION.SDK_INT >= 29`）协商，
/// 仅 Android：桌面端 / Web 没有 `AudioTrack` offload 通路，必须隐藏入口。
bool get supportsAudioOffload => isAndroidPlatform;

/// 蝰蛇母带处理链（10 段均衡 + 限幅，母带级处理）。
///
/// Android 依赖 `LoudnessEnhancer` / `DynamicsProcessing` 等特效 API；
/// iOS 侧由 `AudioEqualizer.swift` 的软件处理链提供等价实现（合并前对 iOS
/// 可见，勿退回仅 Android），关闭时输出逐字节透传。
bool get supportsViperMaster => isMobilePlatform;

/// 音量均衡 / 参考响度（ReLU / 目标 dB 归一）。
///
/// 同样挂在 `EqualizerService` 的音效链上：Android 走原生特效，
/// iOS 走软件处理链，桌面端一并失效。
bool get supportsLoudnessNormalization => isMobilePlatform;

/// 应用内 WebView（`webview_flutter`）。
///
/// **只有 Android/iOS 有平台实现**：Windows 端插件注册表里没有 webview
/// （见 `windows/flutter/ephemeral/.plugin_symlinks/`），`WebViewController()`
/// 会抛 MissingPluginException，整块 UI 被全局 ErrorWidget（"此处内容加载出错"）
/// 替换 —— 曲谱详情页（酷狗 H5 谱面渲染）已踩坑。桌面端调用方必须降级
/// （如用 url_launcher 打开系统浏览器），TV 构建同样视为不支持。
bool get supportsInAppWebView =>
    (isAndroidPlatform || isIOSPlatform) && !kTvBuild;