import 'dart:io';

import 'package:flutter/foundation.dart';

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

/// ---- 平台能力入口 ----
///
/// 桌面端必须隐藏下列入口，否则用户会点进一个永远不生效的页面（历史上已多次
/// 出现：点"USB 独占"却提示"未检测到 USB 音频设备"，完全是死路）。
///
/// 注意区分两类：
/// - **仅 Android**（上游 6.0.0 引入的新项，如震动反馈、预测性手势）：
///   `isAndroidPlatform`。
/// - **移动端（Android + iOS）**：本移植版 iOS 侧有等价实现，必须用
///   `isMobilePlatform` —— 上游原版这里是 `isAndroidPlatform`，会导致 iOS
///   UI 大面积消失（均衡器/音效、听歌识曲、音乐频谱、快捷方式等）。

/// USB 独占输出（Android 走 UAC1 DAC 直写 usbdevfs；iOS 无原生独占，
/// 但页面内已按平台降级为文件头解析的设备/格式状态展示）。
bool get supportsUsbExclusive => isMobilePlatform;

/// 听歌识曲（Android 走 `MediaSession`/麦克风链路；iOS 走麦克风采集 +
/// PiP 悬浮窗识别链路 `SongRecognitionPipManager`）。
bool get supportsSongRecognition => isMobilePlatform;

/// 预测性手势（横滑切歌 / 长按识别等，依赖 Android 系统的
/// `MotionEvent` 手势与振动反馈配合）。iOS 无等价手势实现，保持仅 Android。
bool get supportsPredictiveGesture => isAndroidPlatform;

/// 音乐频谱（Android 走 `Visualizer` 采集 PCM 波形；iOS 走
/// `AVAudioEngine` 采集，见 `spectrum_service.dart` 的 iOS 分支）。
bool get supportsMusicSpectrum => isMobilePlatform;

/// 震动反馈（交互震动 / 音乐节奏震动）。上游 6.0.0 新增项，原版仅 Android；
/// 本移植版 iOS 侧已接入等价实现（交互触感走 `UIFeedbackGenerator`、音乐节奏震动走
/// `CoreHaptics` 跟鼓点，见 `ios/Runner/HapticsPlugin.swift`），故对 iOS 一并开放。
bool get supportsHaptics => isMobilePlatform;

/// 桌面快捷方式（Android 走 `quick_actions_android`；iOS 走
/// `UIApplication.shortcutItems`，由 `ShortcutConfigProvider` 统一配置）。
bool get supportsDesktopShortcut => isMobilePlatform;

/// 系统音效链（均衡器 / 音效库 / 音量均衡 / 响度归一）。
///
/// Android：`EqualizerService` 靠 `AudioSession` + `androidAudioSessionIds`
/// 绑定原生 `android.media.audiofx.Equalizer`。
/// iOS：同一服务走**软件 EQ**（`AVPlayer` + `MTAudioProcessingTap`，见
/// `ios/Runner/AudioEqualizer.swift`），绑定伪会话 id=0，功能等价。
/// 桌面端没有任何等价实现（`tryBind()` 直接 `return false`），必须隐藏。
///
/// ⚠️ 桌面端危险之处：**它不会报错**。`setEnabled(true)` 照样返回成功、
/// 持久化也照样写入，但 `tryBind()` 早已 return false ⇒ 没有任何音效被挂载。
/// 用户看到"已开启"却听不出变化，是典型的假成功。必须隐藏入口。
bool get supportsSystemAudioEffects => isMobilePlatform;

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
