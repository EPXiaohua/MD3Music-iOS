import Flutter
import UIKit
import PhotosUI
import UniformTypeIdentifiers
import MediaPlayer
import AVFoundation
import AVKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate,
    UIDocumentPickerDelegate, PHPickerViewControllerDelegate {
  /// 待回复的 FlutterResult（各选择器互斥，同一时间只允许一个）
  private var pendingResult: FlutterResult?
  /// 当前 UIDocumentPicker 的用途（字体单选 / 音频多选，回调按此分派）
  private var pendingDocPickerKind: DocPickerKind?
  private var channelsConfigured = false

  private enum DocPickerKind { case font, audio }

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    let ok = super.application(application, didFinishLaunchingWithOptions: launchOptions)
    configureChannelsIfPossible()
    return ok
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    configureChannelsIfPossible()
  }

  // MARK: - MethodChannel 注册

  /// Android 端由 MainActivity.kt 实现同名 channel；iOS 在此补齐。
  ///
  /// 注意：场景化生命周期下 AppDelegate.window 为 nil（窗口归 SceneDelegate 所有），
  /// 因此查找 FlutterViewController 必须走 connectedScenes -> keyWindow。
  /// didFinishLaunching / 引擎初始化 / SceneDelegate 连接三处都会尝试注册（幂等）。
  func configureChannelsIfPossible() {
    guard !channelsConfigured else { return }
    guard let vc = findFlutterViewController() else { return }
    let messenger = vc.binaryMessenger

    FlutterMethodChannel(name: "com.md3music.md3music/font_picker", binaryMessenger: messenger)
      .setMethodCallHandler { [weak self] call, result in
        guard call.method == "pickFontFile" else {
          result(FlutterMethodNotImplemented)
          return
        }
        self?.pickFontFile(result: result)
      }

    FlutterMethodChannel(name: "com.md3music.md3music/background_picker", binaryMessenger: messenger)
      .setMethodCallHandler { [weak self] call, result in
        guard call.method == "pickBackgroundImage" else {
          result(FlutterMethodNotImplemented)
          return
        }
        self?.pickBackgroundImage(result: result)
      }

    // 本地音乐导入：UIDocumentPicker 多选音频，拷贝进沙箱后返回文件数
    FlutterMethodChannel(name: "com.md3music.md3music/audio_import", binaryMessenger: messenger)
      .setMethodCallHandler { [weak self] call, result in
        guard call.method == "pickAudioFiles" else {
          result(FlutterMethodNotImplemented)
          return
        }
        self?.pickAudioFiles(result: result)
      }

    // 真实机型（诊断日志用）。iOS 无 MediaStore，Dart 侧 Platform.operatingSystem
    // 只能给出 "ios"；这里返回 utsname.machine 映射出的营销名（如 iPhone 15 Pro）。
    FlutterMethodChannel(name: "com.md3music.md3music/device_info", binaryMessenger: messenger)
      .setMethodCallHandler { call, result in
        guard call.method == "getModel" else {
          result(FlutterMethodNotImplemented)
          return
        }
        result(AppDelegate.deviceModelName())
      }

    // iOS 锁屏/控制中心 Now Playing 信息与远程命令。
    // Android 的锁屏/通知由 Media3 MediaSession 负责，不经过此 channel，
    // 本 channel 仅在 iOS Runner 内注册，互不影响。
    NowPlayingManager.shared.attach(messenger: messenger)

    // iOS 桌面小组件数据同步（与 Android 同名 channel，原生各自实现）
    WidgetSync.shared.attach(messenger: messenger)

    // iOS 歌词悬浮窗（系统画中画）。Android 悬浮歌词走 FloatingLyricService，
    // 本 channel 仅在 iOS Runner 内注册，互不影响。
    LyricsPipManager.shared.attach(messenger: messenger)

    // iOS 听歌识曲悬浮窗（系统画中画）。Android 悬浮识曲走 FloatingRecognitionService，
    // 本 channel 仅在 iOS Runner 内注册，互不影响。
    SongRecognitionPipManager.shared.attach(messenger: messenger)

    // iOS 震动反馈：交互触感（UIFeedbackGenerator）+ m3e 滑条震动 + 音乐节奏震动
    // （CoreHaptics）。与 Android 的 md3music/haptics、m3e_haptics/haptics、
    // com.md3music.md3music/music_haptics 三个 channel 同名，原生各自实现。
    HapticsBridge.shared.attach(messenger: messenger)
    MusicHapticsEngine.shared.attach(messenger: messenger)

    // iOS 3D 封面（Depth Anything V2 推理 + push-pull/MI-GAN 修补 + 三层切割）。
    // 仅 3D 包定义 DEPTH_3D_LINKED（CI 写入链接 xcconfig）；标准包此段编译为空，
    // Dart 侧 MissingPluginException 走平面封面回退。
#if DEPTH_3D_LINKED
    DepthCoverPlugin.shared.attach(messenger: messenger)
#endif

    channelsConfigured = true
    NSLog("[MD3Music] picker MethodChannels registered on FlutterViewController")
  }

  /// 通过 connectedScenes 找 keyWindow 的根 FlutterViewController
  private func findFlutterViewController() -> FlutterViewController? {
    let windows = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap { $0.windows }
    for window in windows {
      guard let root = window.rootViewController else { continue }
      if let vc = root as? FlutterViewController {
        return vc
      }
      // 根不是（例如被导航/容器包住）时向下找一层
      for child in root.children {
        if let vc = child as? FlutterViewController {
          return vc
        }
      }
    }
    return nil
  }

  /// 当前可用于 present 的最顶层控制器
  private var presenter: UIViewController? {
    let windows = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap { $0.windows }
    var base = windows.first { $0.isKeyWindow }?.rootViewController
      ?? windows.first?.rootViewController
    while let presented = base?.presentedViewController {
      base = presented
    }
    return base
  }

  /// 真实机型：utsname.machine 机器标识 → 营销名（诊断日志用）。
  /// 未收录的新设备回退到标识符本身（如 "iPhone18,1"），仍是有效机型信息。
  static func deviceModelName() -> String {
    var systemInfo = utsname()
    uname(&systemInfo)
    let identifier = withUnsafePointer(to: &systemInfo.machine) {
      $0.withMemoryRebound(to: CChar.self, capacity: 1) {
        String(cString: $0)
      }
    }
    let names: [String: String] = [
      // iPhone
      "iPhone8,1": "iPhone 6s", "iPhone8,2": "iPhone 6s Plus", "iPhone8,4": "iPhone SE (1st gen)",
      "iPhone9,1": "iPhone 7", "iPhone9,3": "iPhone 7", "iPhone9,2": "iPhone 7 Plus", "iPhone9,4": "iPhone 7 Plus",
      "iPhone10,1": "iPhone 8", "iPhone10,4": "iPhone 8", "iPhone10,2": "iPhone 8 Plus", "iPhone10,5": "iPhone 8 Plus",
      "iPhone10,3": "iPhone X", "iPhone10,6": "iPhone X",
      "iPhone11,2": "iPhone XS", "iPhone11,4": "iPhone XS Max", "iPhone11,6": "iPhone XS Max",
      "iPhone11,8": "iPhone XR",
      "iPhone12,1": "iPhone 11", "iPhone12,3": "iPhone 11 Pro", "iPhone12,5": "iPhone 11 Pro Max",
      "iPhone12,8": "iPhone SE (2nd gen)",
      "iPhone13,1": "iPhone 12 mini", "iPhone13,2": "iPhone 12", "iPhone13,3": "iPhone 12 Pro", "iPhone13,4": "iPhone 12 Pro Max",
      "iPhone14,4": "iPhone 13 mini", "iPhone14,5": "iPhone 13", "iPhone14,2": "iPhone 13 Pro", "iPhone14,3": "iPhone 13 Pro Max",
      "iPhone14,6": "iPhone SE (3rd gen)",
      "iPhone14,7": "iPhone 14", "iPhone14,8": "iPhone 14 Plus", "iPhone15,2": "iPhone 14 Pro", "iPhone15,3": "iPhone 14 Pro Max",
      "iPhone15,4": "iPhone 15", "iPhone15,5": "iPhone 15 Plus", "iPhone16,1": "iPhone 15 Pro", "iPhone16,2": "iPhone 15 Pro Max",
      "iPhone17,3": "iPhone 16", "iPhone17,4": "iPhone 16 Plus", "iPhone17,5": "iPhone 16 Pro", "iPhone17,6": "iPhone 16 Pro Max",
      // iPad（常见款，其余回退标识符）
      "iPad6,11": "iPad (5th gen)", "iPad6,12": "iPad (5th gen)",
      "iPad7,5": "iPad (6th gen)", "iPad7,6": "iPad (6th gen)",
      "iPad7,11": "iPad (7th gen)", "iPad7,12": "iPad (7th gen)",
      "iPad11,6": "iPad (8th gen)", "iPad11,7": "iPad (8th gen)",
      "iPad12,1": "iPad (9th gen)", "iPad12,2": "iPad (9th gen)",
      "iPad13,18": "iPad (10th gen)", "iPad13,19": "iPad (10th gen)",
      "iPad8,1": "iPad Pro 11 (1st gen)", "iPad8,2": "iPad Pro 11 (1st gen)",
      "iPad8,9": "iPad Pro 11 (2nd gen)", "iPad8,10": "iPad Pro 11 (2nd gen)",
      "iPad13,4": "iPad Pro 11 (3rd gen)", "iPad13,5": "iPad Pro 11 (3rd gen)",
      "iPad14,3": "iPad Pro 11 (4th gen)", "iPad14,4": "iPad Pro 11 (4th gen)",
      "iPad8,5": "iPad Pro 12.9 (3rd gen)", "iPad8,6": "iPad Pro 12.9 (3rd gen)",
      "iPad8,11": "iPad Pro 12.9 (4th gen)", "iPad8,12": "iPad Pro 12.9 (4th gen)",
      "iPad13,8": "iPad Pro 12.9 (5th gen)", "iPad13,9": "iPad Pro 12.9 (5th gen)",
      "iPad14,5": "iPad Pro 12.9 (6th gen)", "iPad14,6": "iPad Pro 12.9 (6th gen)",
      "iPad13,1": "iPad Air (4th gen)", "iPad13,2": "iPad Air (4th gen)",
      "iPad13,16": "iPad Air (5th gen)", "iPad13,17": "iPad Air (5th gen)",
      "iPad11,3": "iPad Air (3rd gen)", "iPad11,4": "iPad Air (3rd gen)",
      "iPad5,3": "iPad Air 2", "iPad5,4": "iPad Air 2",
      "iPad14,8": "iPad Air (11in, M2)", "iPad14,9": "iPad Air (11in, M2)",
    ]
    guard let name = names[identifier] else { return identifier }
    return "\(name) (\(identifier))"
  }

  // MARK: - 字体文件选择（对齐 Android SAF：拷贝到 Documents/fonts/ 后返回路径）

  private func pickFontFile(result: @escaping FlutterResult) {
    guard pendingResult == nil else {
      result(nil)  // 已有选择器在运行，直接视为取消
      return
    }
    guard let presenter = presenter else {
      result(FlutterError(code: "NO_VIEW_CONTROLLER", message: "无法获取展示控制器", details: nil))
      return
    }
    pendingResult = result
    pendingDocPickerKind = .font
    // UTType 没有字体静态成员，用标准 UTI 构造：ttf / otf / 通用字体
    let fontTypes = [
      UTType("public.truetype-ttf"),
      UTType("public.opentype-font"),
      UTType("public.font"),
    ].compactMap { $0 }
    let picker = UIDocumentPickerViewController(
      forOpeningContentTypes: fontTypes, asCopy: true)
    picker.delegate = self
    picker.allowsMultipleSelection = false
    presenter.present(picker, animated: true)
  }

  // MARK: - 音频导入（本地音乐：DocumentPicker 多选，拷入沙箱后返回文件数）

  private func pickAudioFiles(result: @escaping FlutterResult) {
    guard pendingResult == nil else {
      result(0)  // 已有选择器在运行，视为取消
      return
    }
    guard let presenter = presenter else {
      result(FlutterError(code: "NO_VIEW_CONTROLLER", message: "无法获取展示控制器", details: nil))
      return
    }
    pendingResult = result
    pendingDocPickerKind = .audio
    // 常见音频 UTI + 冷门扩展名动态构造（ape/wma 无标准 UTI）
    var audioTypes: Set<UTType> = [
      .audio, .mp3, .mpeg4Audio, .wav, .aiff,
    ]
    for ext in ["ape", "wma", "opus", "ogg", "aif", "m4a", "aac", "flac"] {
      if let t = UTType(filenameExtension: ext) { audioTypes.insert(t) }
    }
    let picker = UIDocumentPickerViewController(
      forOpeningContentTypes: Array(audioTypes), asCopy: true)
    picker.delegate = self
    picker.allowsMultipleSelection = true
    presenter.present(picker, animated: true)
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    guard let result = pendingResult else { return }
    pendingResult = nil
    let kind = pendingDocPickerKind
    pendingDocPickerKind = nil
    guard let src = urls.first, !urls.isEmpty else {
      result(kind == .audio ? 0 : nil)
      return
    }
    switch kind {
    case .audio:
      result(handleAudioPicked(urls))
    default:
      handleFontPicked(src, result: result)
    }
  }

  /// 音频导入：拷进 Documents/Music/Imports/（保留原文件名，同名加时间戳），
  /// 返回成功拷入的文件数
  private func handleAudioPicked(_ urls: [URL]) -> Int {
    do {
      let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
      let dir = docs.appendingPathComponent("Music/Imports", isDirectory: true)
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      let ts = Int(Date().timeIntervalSince1970 * 1000)
      var copied = 0
      for src in urls {
        let rawName = src.lastPathComponent
        let dot = rawName.lastIndex(of: ".")
        let base: String
        let ext: String
        if let dot {
          base = String(rawName[..<dot])
          ext = String(rawName[dot...])
        } else {
          base = rawName
          ext = ""
        }
        var name = rawName
        if FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path) {
          name = "\(base)_\(ts)\(ext)"
        }
        try FileManager.default.copyItem(
          at: src, to: dir.appendingPathComponent(name))
        copied += 1
      }
      return copied
    } catch {
      NSLog("[MD3Music] audio import copy failed: \(error)")
      return 0
    }
  }

  private func handleFontPicked(_ src: URL, result: @escaping FlutterResult) {
    do {
      let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
      let dir = docs.appendingPathComponent("fonts", isDirectory: true)
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      let ext = src.pathExtension.isEmpty ? "ttf" : src.pathExtension
      // 关键：时间戳唯一命名（对齐背景图 bg_<ts> 实现）。固定文件名 user_custom.ttf
      // 会让 Dart 端 setCustomFontPath 判定路径未变化而跳过重新加载，第二次换字体不生效。
      let name = "font_\(Int(Date().timeIntervalSince1970 * 1000)).\(ext)"
      let dst = dir.appendingPathComponent(name)
      try FileManager.default.copyItem(at: src, to: dst)
      // 清理旧字体文件，只保留刚拷贝的一份。
      // 注意：必须用 lastPathComponent（文件名）比较，contentsOfDirectory 返回的
      // 路径拼写（/private 前缀等）与 dst.path 可能不同，整条路径比较会把
      // 刚写入的文件误判为旧文件删除掉。
      if let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
        for old in files where old.isFileURL
            && old.lastPathComponent != dst.lastPathComponent
            && (old.lastPathComponent.hasPrefix("font_") || old.lastPathComponent.hasPrefix("user_custom")) {
          try? FileManager.default.removeItem(at: old)
        }
      }
      result(dst.path)
    } catch {
      result(FlutterError(code: "FONT_COPY_FAILED", message: error.localizedDescription, details: nil))
    }
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    guard let result = pendingResult else { return }
    pendingResult = nil
    let kind = pendingDocPickerKind
    pendingDocPickerKind = nil
    result(kind == .audio ? 0 : nil)
  }

  // MARK: - 背景图片选择（对齐 Android SAF：拷贝到 Documents/background/ 后返回路径）

  private func pickBackgroundImage(result: @escaping FlutterResult) {
    guard pendingResult == nil else {
      result(nil)
      return
    }
    guard let presenter = presenter else {
      result(FlutterError(code: "NO_VIEW_CONTROLLER", message: "无法获取展示控制器", details: nil))
      return
    }
    pendingResult = result
    var config = PHPickerConfiguration()
    config.filter = .images
    config.selectionLimit = 1
    let picker = PHPickerViewController(configuration: config)
    picker.delegate = self
    presenter.present(picker, animated: true)
  }

  func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
    picker.dismiss(animated: true)
    guard let result = pendingResult else { return }
    guard let provider = results.first?.itemProvider,
          provider.canLoadObject(ofClass: UIImage.self) else {
      pendingResult = nil
      result(nil)
      return
    }
    // loadObject 回调在任意队列，FlutterResult 必须回主线程
    provider.loadObject(ofClass: UIImage.self) { [weak self] obj, _ in
      guard let self = self else { return }
      guard let image = obj as? UIImage else {
        DispatchQueue.main.async {
          self.pendingResult = nil
          result(nil)
        }
        return
      }
      do {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("background", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // 关键：时间戳唯一命名（对齐 Android 端 bg_<ts> 实现）。
        // 固定文件名会让 Flutter Image.file 按路径命中旧缓存，更换图片后仍显示第一张。
        let name = "bg_\(Int(Date().timeIntervalSince1970 * 1000)).jpg"
        let dst = dir.appendingPathComponent(name)
        guard let data = image.jpegData(compressionQuality: 0.95) else {
          DispatchQueue.main.async {
            self.pendingResult = nil
            result(nil)
          }
          return
        }
        try data.write(to: dst)
        // 写入成功后清理旧背景文件，避免累积（只保留刚写的一份）。
        // 同字体清理：必须用文件名比较，整条路径比较会误删刚写入的文件。
        if let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
          for old in files where old.isFileURL
              && old.lastPathComponent != dst.lastPathComponent
              && (old.lastPathComponent.hasPrefix("bg_") || old.lastPathComponent == "background.jpg") {
            try? FileManager.default.removeItem(at: old)
          }
        }
        DispatchQueue.main.async {
          self.pendingResult = nil
          result(dst.path)
        }
      } catch {
        DispatchQueue.main.async {
          self.pendingResult = nil
          result(FlutterError(code: "BG_COPY_FAILED", message: error.localizedDescription, details: nil))
        }
      }
    }
  }
}

// MARK: - iOS 锁屏/控制中心 Now Playing

/// iOS 锁屏/控制中心 Now Playing 信息与远程命令桥接。
///
/// 与 Android 的 Media3 通知路径互不影响：本类只在 iOS Runner 内编译，
/// channel 也只由 iOS 端注册。Dart 端对应 lib/core/services/now_playing_service.dart。
final class NowPlayingManager {
  static let shared = NowPlayingManager()

  private var channel: FlutterMethodChannel?
  /// 当前倍速对应的 rate（暂停时必须为 0，否则锁屏进度条按墙钟自己走）
  private var currentRate: Double = 0
  /// 已应用到锁屏的封面 URI：同曲重复刷新（通知重建/收藏变化等）不重复下载
  private var appliedArtUri: String?
  /// 封面下载请求序号：快速切歌时旧请求返回后按序号丢弃，避免串歌封面
  private var artworkRequestId = 0
  /// 最近一次成功加载的封面（桌面小组件 WidgetSync 读取）
  var lastArtworkImage: UIImage?

  private init() {}

  /// 注册 MethodChannel 与远程命令（幂等）。attach 与命令回调均保证在主线程。
  func attach(messenger: FlutterBinaryMessenger) {
    guard channel == nil else { return }
    let ch = FlutterMethodChannel(name: "com.md3music/now_playing", binaryMessenger: messenger)
    ch.setMethodCallHandler { [weak self] call, result in
      self?.handle(call: call, result: result)
    }
    channel = ch
    registerRemoteCommands()
    NSLog("[MD3Music] now_playing channel registered")
  }

  private func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "setMetadata":
      guard let args = call.arguments as? [String: Any] else {
        result(nil)
        return
      }
      setMetadata(args)
      result(nil)
    case "updatePlayback":
      guard let args = call.arguments as? [String: Any] else {
        result(nil)
        return
      }
      updatePlayback(args)
      result(nil)
    case "clear":
      clear()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: 元数据（标题/歌手/专辑/时长 + 封面异步下载）

  private func setMetadata(_ args: [String: Any]) {
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      // 增量更新：保留封面等已有字段，不重建整个 dict
      var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
      let newTitle = args["title"] as? String
      let oldTitle = info[MPMediaItemPropertyTitle] as? String
      // 仅切歌（标题变化）时进度归零；同曲刷新（暂停/收藏/封面覆盖路径等
      // 重建通知）保留进度，避免把锁屏进度打回 0。
      let isTrackChange = newTitle != nil && newTitle != oldTitle
      if let title = newTitle, !title.isEmpty {
        info[MPMediaItemPropertyTitle] = title
      }
      if let artist = args["artist"] as? String {
        info[MPMediaItemPropertyArtist] = artist
      }
      if let album = args["album"] as? String {
        info[MPMediaItemPropertyAlbumTitle] = album
      }
      if let durationMs = (args["duration"] as? NSNumber)?.doubleValue, durationMs > 0 {
        info[MPMediaItemPropertyPlaybackDuration] = durationMs / 1000.0
      }
      if isTrackChange {
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = 0.0
        info[MPNowPlayingInfoPropertyPlaybackRate] = self.currentRate
      }
      MPNowPlayingInfoCenter.default().nowPlayingInfo = info
      self.loadArtwork(args["artUri"] as? String)
    }
  }

  /// 异步取封面：http/https/file 均由 URLSession 支持（Info.plist 已放行 ATS）。
  /// 成功构造 MPMediaItemArtwork（handler 返回对应尺寸 UIImage）后重新刷新
  /// nowPlayingInfo；失败静默跳过（锁屏仍显示文字）。
  private func loadArtwork(_ artUri: String?) {
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      // 空 URI 的推送（局部更新等）：清掉锁屏旧封面，但 appliedArtUri 保持
      // 原值——若在这里清空，下一次带 URI 的推送会被判为新封面而重复下载，
      // 生成新的 UIImage 实例，PiP 模糊背景按指针比对误判切歌反复重模糊
      //（低遮罩不透明度下表现为背景黑↔封面闪烁）。
      guard let uri = artUri, !uri.isEmpty else {
        if self.appliedArtUri != nil { self.removeArtwork() }
        return
      }
      if uri == self.appliedArtUri { return }
      self.appliedArtUri = uri
      self.artworkRequestId += 1
      let requestId = self.artworkRequestId
      guard let url = URL(string: uri) else {
        self.removeArtwork()
        return
      }
      URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
        guard let self = self else { return }
        DispatchQueue.main.async {
          // 已切歌：丢弃过期封面
          guard requestId == self.artworkRequestId else { return }
          guard let data = data, let image = UIImage(data: data) else { return }
          let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
          // 供桌面小组件（WidgetSync）取用当前封面
          self.lastArtworkImage = image
          var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
          info[MPMediaItemPropertyArtwork] = artwork
          MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        }
      }.resume()
    }
  }

  private func removeArtwork() {
    var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
    info[MPMediaItemPropertyArtwork] = nil
    MPNowPlayingInfoCenter.default().nowPlayingInfo = info
  }

  // MARK: 播放进度/状态

  private func updatePlayback(_ args: [String: Any]) {
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      let positionMs = (args["position"] as? NSNumber)?.doubleValue ?? 0
      let playing = args["playing"] as? Bool ?? false
      let speed = (args["speed"] as? NSNumber)?.doubleValue ?? 1.0
      // 暂停时 rate=0：锁屏进度条停止走动
      let rate: Double = playing ? (speed > 0 ? speed : 1.0) : 0
      self.currentRate = rate
      // 增量更新：保持标题/封面字段
      var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
      info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = positionMs / 1000.0
      info[MPNowPlayingInfoPropertyPlaybackRate] = rate
      info[MPNowPlayingInfoPropertyPlaybackQueueIndex] = 0
      MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
  }

  private func clear() {
    DispatchQueue.main.async { [weak self] in
      MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
      self?.appliedArtUri = nil
      self?.currentRate = 0
      self?.artworkRequestId += 1
    }
  }

  // MARK: 远程命令（锁屏/控制中心/耳机线控）→ Flutter

  private func registerRemoteCommands() {
    let center = MPRemoteCommandCenter.shared()
    center.togglePlayPauseCommand.addTarget { [weak self] _ in
      self?.sendCommand("toggle")
      return .success
    }
    center.playCommand.addTarget { [weak self] _ in
      self?.sendCommand("play")
      return .success
    }
    center.pauseCommand.addTarget { [weak self] _ in
      self?.sendCommand("pause")
      return .success
    }
    center.nextTrackCommand.addTarget { [weak self] _ in
      self?.sendCommand("next")
      return .success
    }
    center.previousTrackCommand.addTarget { [weak self] _ in
      self?.sendCommand("previous")
      return .success
    }
    // 控制中心进度条拖动
    center.changePlaybackPositionCommand.addTarget { [weak self] event in
      guard let event = event as? MPChangePlaybackPositionCommandEvent else {
        return .commandFailed
      }
      self?.sendCommand("seek", positionMs: Int(event.positionTime * 1000))
      return .success
    }
    center.togglePlayPauseCommand.isEnabled = true
    center.playCommand.isEnabled = true
    center.pauseCommand.isEnabled = true
    center.nextTrackCommand.isEnabled = true
    center.previousTrackCommand.isEnabled = true
    center.changePlaybackPositionCommand.isEnabled = true
  }

  /// 命令回传 Dart：invokeMethod("command", {'action': ..., 'position': <ms>}).
  private func sendCommand(_ action: String, positionMs: Int? = nil) {
    DispatchQueue.main.async { [weak self] in
      var args: [String: Any] = ["action": action]
      if let positionMs = positionMs {
        args["position"] = positionMs
      }
      self?.channel?.invokeMethod("command", arguments: args)
    }
  }
}

// MARK: - iOS 歌词悬浮窗（系统画中画 · SampleBuffer 帧管线）

/// iOS 歌词悬浮窗：系统画中画，SampleBuffer contentSource + 自绘帧管线。
///
/// 与 Android 的 FloatingLyricService 悬浮窗路径互不影响：本类只在 iOS Runner
/// 内编译，channel 也只由 iOS 端注册。Dart 端对应 lib/core/services/lyrics_pip_service.dart。
///
/// 方案：
/// - AVSampleBufferDisplayLayer 挂在离屏宿主视图上保持窗口层级，CVPixelBufferPool
///   帧管线：每帧把歌词条画进 UIGraphicsImageRenderer 得到位图，blit 进
///   CVPixelBuffer 后包成 CMSampleBuffer（hostTime PTS + DisplayImmediately）
///   enqueue；iOS17+ 走 sampleBufferRenderer，failed 态先 flush 再入帧（failed
///   的 renderer 会静默吞帧，表现为画面冻结）；
/// - ContentSource(sampleBufferDisplayLayer:playbackDelegate:) 的小窗交互：
///   点窗口浮现系统自带的关闭(X)/还原按钮；controlsStyle 私有样式去掉播放/
///   跳过等传输控件，requiresLinearPlayback 兜底；
/// - AVPictureInPictureSampleBufferPlaybackDelegate 按"只读仪表"语义实现：
///   不响应播放/seek（setPlaying 空、timeRange 无限、isPlaybackPaused false、
///   skipByInterval 直接 completion、不禁止后台音频——音乐是本 app 在放）；
///   restoreUserInterface 回调返回 true，点系统关闭/还原按钮都把 App 拉回前台；
/// - 帧驱动用主线程 Timer（50ms ≈ 20fps）而非 CADisplayLink：App 退后台
///   （音频后台模式）时 displayLink 随屏幕刷新停摆，Timer 仍持续出帧；
/// - 启动重试：等宿主视图进层级 + 已画出首帧（layer 无帧系统拒绝开窗）+
///   isPictureInPicturePossible 后再 startPictureInPicture（最多 8 次，
///   0.02/0.12s 间隔）。
///
/// 渲染：每帧 NSString/UIFont 画单/双行细条（宽 300pt；高随设置页「版式 →
/// 字号」缩放：单行 22pt 基准、双行 44pt 基准 @18sp，@2x 位图）——
/// 主行当前句逐字卡拉OK（粗体），双行时副行下一句整行灰未唱色（细体、
/// 静态不滚动——副行是未唱预览，不跟随主行滚动）。
/// 卡拉OK文字蒙版式（对齐安卓 GradientTextView）：整行先画未唱色，再 clip
/// 已唱宽度重画渐变色层，蒙版硬边随播放逐字向右扫过；已唱渐变 = 设置页
/// 「设备歌词」配色下发的 gradientStart→gradientEnd（默认青 0xFF00E5FF→紫
/// 0xFFFF00FF）按行内 x 位置采样，未唱色默认灰 0xFF666666。底部细进度条。
/// 行进度原生自推进：
/// 以 Dart 最近推送的 positionMs 为锚点 + 本机单调时钟流逝推算，Dart tick 定期校准。
/// 行超宽不省略号：着色前沿驱动 easeOut 向左滚动（单向不往返、换行复位贴左）。

final class LyricsPipManager: NSObject {
  static let shared = LyricsPipManager()

  private var channel: FlutterMethodChannel?
  /// 整包歌词（按时间升序）：底部进度条总长用
  private var lines: [(start: Int, duration: Int, text: String, translation: String?)] = []

  // 当前句（Dart 行切换时推送 setLine）
  private var lineText = ""
  private var lineWords: [(text: String, start: Int, duration: Int)] = []
  /// 当前行 startMs：在整包 lines 里定位 index，供副行取下一句
  private var lineStartMs = -1
  /// 副行文本（整包歌词里当前句的下一句，对齐安卓 doubleLine 副行）
  private var nextLineText = ""
  // 滚动状态：卡拉OK着色前沿驱动、easeOut 单向跟随（替代 ping-pong 往返）。
  // 行首贴左静止，着色接近视口右缘前才开始向左滚出后续字；换行重置贴左。
  private var scrollOffset: CGFloat = 0
  private var scrollLastUptime: TimeInterval = 0
  /// 滚动状态所属行（换行时重置回贴左）
  private var scrollLineStartMs = -1
  /// 占位文案（歌词加载中.../暂无歌词/歌词加载失败），空 = 正常渲染行
  private var placeholder = ""

  // 版式配置（设置页「设备歌词」经 configure 下发；默认对齐 Dart：18sp / 单行）。
  // 字号驱动 PiP 条高度，行式切单/双行渲染。
  private var configFontSize: Double = 18.0
  private var configDoubleLine = false
  // 配色（ARGB，与安卓悬浮窗同一组值；默认 = FloatingLyricService 默认渐变）。
  private var configSungStartARGB = LyricsPipManager.sungColorStartARGB
  private var configSungEndARGB = LyricsPipManager.sungColorEndARGB
  private var configUnplayedARGB = LyricsPipManager.unplayedARGB
  // 黑色遮罩不透明度（0–100，设置页「设备歌词」的不透明度滑杆）。
  // 底下铺当前歌曲封面高斯模糊背景，遮罩 alpha = opacity/100；无封面时
  // 直接实色黑。默认 50 对齐 Dart 侧初始值。
  private var configOpacity: Int = 50
  // 模糊封面背景：封面取自 NowPlayingManager（WidgetSync 小组件同源），
  // 帧循环里指针比对发现切歌/条尺寸变化后，后台队列重出模糊图再回主
  // 线程重绘——模糊每封面只做一次，20fps 帧循环只多一次指针比较。
  private var coverImage: UIImage?
  private var blurredCover: CGImage?
  private var blurredCoverSize: CGSize = .zero
  private var coverBlurPending = false
  private let coverQueue = DispatchQueue(label: "com.md3music.lyricspip.cover", qos: .utility)
  private static let ciContext = CIContext()

  // 进度锚点：Dart 最近推送的 positionMs + 接收时刻（本机单调钟）
  private var anchorPositionMs: Double = 0
  private var anchorUptime: TimeInterval = 0
  private var playing = false

  /// SampleBuffer 帧管线显示层（挂离屏宿主视图，保持窗口层级）
  private let sampleLayer = AVSampleBufferDisplayLayer()
  /// 离屏宿主视图（只为让 layer 处于窗口层级，本体移出屏幕）
  private var hostView: UIView?
  /// CVPixelBufferPool（尺寸不变则复用）
  private var pixelPool: CVPixelBufferPool?
  private var poolSize = CGSize.zero
  /// 已向 layer 画过帧（layer 无帧时系统拒绝开窗）
  private var hasPainted = false
  /// 帧驱动定时器（PiP 激活期间 20fps 出帧；Timer 后台仍触发）
  private var frameTimer: Timer?
  private var pipController: AVPictureInPictureController?
  /// controller.delegate 为弱引用，必须自行持有
  private var delegateHolder: AnyObject?
  /// 启动重试（等宿主进层级 + 首帧 + isPictureInPicturePossible）
  private var startRetry: DispatchWorkItem?
  /// PiP 开关状态机：startPictureInPicture / stopPictureInPicture 都是异步
  /// 指令，快速连点开关时上一个操作未完成又收到反向指令，会让 controller
  /// 状态失步（永远起不来或关不掉）。状态只由 delegate 终态回调（didStart /
  /// didStop / failedToStart）推进；请求到达时若操作在途，仅记录 pendingIntent，
  /// 回调到达后收敛执行，保证最终状态与最后一次用户意图一致。
  private enum PipState { case idle, starting, started, stopping }
  private var state: PipState = .idle
  /// 在途时收到的最后一次用户意图（true=想开，false=想关）；nil=无待收敛意图
  private var pendingIntent: Bool?
  /// 已真正调用 startPictureInPicture()、等待系统 didStart/failed 回调
  private var awaitingStartCallback = false
  /// 条状画布尺寸（pt）：宽度固定 300；高度 = 基准高 × 字号缩放（18sp 归一，
  /// 下限 8sp 防御持久层脏数据出 0 高帧）。单行基准 22pt、双行 44pt——
  /// 设置页「版式 → 字号」滑杆即 PiP 高度滑杆。
  private var barSize: CGSize {
    let scale = CGFloat(max(configFontSize, 8) / 18.0)
    return CGSize(width: 300, height: ((configDoubleLine ? 44.0 : 22.0) * scale).rounded())
  }

  private override init() {}

  /// 注册 MethodChannel（幂等）。attach 与各方法均保证在主线程执行。
  func attach(messenger: FlutterBinaryMessenger) {
    guard channel == nil else { return }
    let ch = FlutterMethodChannel(name: "com.md3music/lyrics_pip", binaryMessenger: messenger)
    ch.setMethodCallHandler { [weak self] call, result in
      self?.handle(call: call, result: result)
    }
    channel = ch
    NSLog("[MD3Music] lyrics_pip channel registered")
  }

  private func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
    DispatchQueue.main.async { [weak self] in
      guard let self = self else {
        result(FlutterError(code: "gone", message: "LyricsPipManager deallocated", details: nil))
        return
      }
      switch call.method {
      case "start":
        self.start(result: result)
      case "stop":
        self.stop(result: result)
      case "setLyrics":
        if let args = call.arguments as? [String: Any] {
          self.setLyrics(args)
        }
        result(nil)
      case "setLine":
        if let args = call.arguments as? [String: Any] {
          self.setLine(args)
        }
        result(nil)
      case "update":
        if let args = call.arguments as? [String: Any] {
          self.update(args)
        }
        result(nil)
      case "configure":
        if let args = call.arguments as? [String: Any] {
          self.configure(args)
        }
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  // MARK: setLyrics（整包歌词下发，切歌/解析完成时一次）

  private func setLyrics(_ args: [String: Any]) {
    var parsed: [(start: Int, duration: Int, text: String, translation: String?)] = []
    if let rawLines = args["lines"] as? [[String: Any]] {
      for raw in rawLines {
        let start = (raw["start"] as? NSNumber)?.intValue ?? 0
        let duration = (raw["duration"] as? NSNumber)?.intValue ?? 0
        let text = raw["text"] as? String ?? ""
        let translation = raw["translation"] as? String
        parsed.append((start, duration, text, (translation?.isEmpty ?? true) ? nil : translation))
      }
    }
    parsed.sort { $0.start < $1.start }
    lines = parsed
    recomputeNextLine()
  }

  // MARK: setLine（当前行 + 逐字时间轴 + 进度校准）

  private func setLine(_ args: [String: Any]) {
    lineText = args["text"] as? String ?? ""
    lineStartMs = (args["lineStart"] as? NSNumber)?.intValue ?? -1
    placeholder = args["placeholder"] as? String ?? ""
    var words: [(text: String, start: Int, duration: Int)] = []
    if let rawWords = args["words"] as? [[String: Any]] {
      for raw in rawWords {
        words.append((
          text: raw["t"] as? String ?? "",
          start: (raw["s"] as? NSNumber)?.intValue ?? 0,
          duration: (raw["d"] as? NSNumber)?.intValue ?? 0
        ))
      }
    }
    lineWords = words
    anchorPositionMs = (args["positionMs"] as? NSNumber)?.doubleValue ?? 0
    anchorUptime = ProcessInfo.processInfo.systemUptime
    playing = args["playing"] as? Bool ?? false
    if lineStartMs != scrollLineStartMs {
      // 换行：滚动重置回贴左
      scrollOffset = 0
      scrollLastUptime = 0
      scrollLineStartMs = lineStartMs
    }
    recomputeNextLine()
  }

  /// 副行 = 整包歌词里当前句的下一句（安卓 FloatingLyricService 的
  /// doubleLine 副行逻辑：lyricText2 显示 nextLyric，无下一句则隐藏）。
  private func recomputeNextLine() {
    guard lineStartMs >= 0, !lines.isEmpty,
      let idx = lines.firstIndex(where: { $0.start == lineStartMs }),
      idx + 1 < lines.count
    else {
      nextLineText = ""
      return
    }
    nextLineText = lines[idx + 1].text
  }

  // MARK: update（进度/播放状态校准，间奏与进度条推进用）

  private func update(_ args: [String: Any]) {
    anchorPositionMs = (args["position"] as? NSNumber)?.doubleValue ?? 0
    anchorUptime = ProcessInfo.processInfo.systemUptime
    playing = args["playing"] as? Bool ?? false
  }

  // MARK: configure（外观：字号 / 行式 / 配色，设置页「设备歌词」下发）

  private func configure(_ args: [String: Any]) {
    // Dart int 经 StandardMessageCodec 可能落在 Int64（ARGB 常带高bit，
    // 如 0xFFFF00FF 超出 Int32），必须用 int64Value 取，intValue 会回绕。
    let fs = (args["fontSize"] as? NSNumber)?.doubleValue
    let dl = (args["doubleLine"] as? NSNumber)?.boolValue
    let gs = (args["gradientStart"] as? NSNumber).map { Int($0.int64Value) }
    let ge = (args["gradientEnd"] as? NSNumber).map { Int($0.int64Value) }
    let uc = (args["unplayedColor"] as? NSNumber).map { Int($0.int64Value) }
    let op = (args["opacity"] as? NSNumber)?.intValue
    var layoutChanged = false
    if let fs, fs != configFontSize {
      configFontSize = fs
      layoutChanged = true
    }
    if let dl, dl != configDoubleLine {
      configDoubleLine = dl
      layoutChanged = true
    }
    var colorChanged = false
    if let gs, gs != configSungStartARGB {
      configSungStartARGB = gs
      colorChanged = true
    }
    if let ge, ge != configSungEndARGB {
      configSungEndARGB = ge
      colorChanged = true
    }
    if let uc, uc != configUnplayedARGB {
      configUnplayedARGB = uc
      colorChanged = true
    }
    if let op, op != configOpacity {
      configOpacity = max(0, min(100, op))
      colorChanged = true
    }
    // 版式变化要重建条尺寸并复位滚动；纯配色变化只需重出一帧
    // （滚动偏移复位会把已滚到中途的行瞬间弹回行首，不能共用）。
    if layoutChanged {
      applyBarSize()
    } else if colorChanged {
      renderFrame()
    }
  }

  /// 条高变化：同步离屏宿主/显示层尺寸、复位滚动状态并立即重出一帧。
  /// 像素池按尺寸缓存（pixelBufferPool），barSize 变化自动重建；PiP 窗口
  /// 随新帧宽高比自适应。
  private func applyBarSize() {
    scrollOffset = 0
    scrollLastUptime = 0
    if let host = hostView {
      host.frame = CGRect(
        x: -barSize.width - 16, y: -8,
        width: barSize.width, height: barSize.height)
      sampleLayer.frame = host.bounds
    }
    renderFrame()
  }

  /// 估算当前播放位置：锚点 + 本机单调钟流逝（播放中原生自推进）。
  private var estimatedPositionMs: Double {
    guard playing, anchorUptime > 0 else { return anchorPositionMs }
    let elapsedMs = (ProcessInfo.processInfo.systemUptime - anchorUptime) * 1000
    return anchorPositionMs + elapsedMs
  }

  // MARK: start / stop

  private func start(result: @escaping FlutterResult) {
    guard #available(iOS 15.0, *) else {
      result(FlutterError(
        code: "unsupported",
        message: "Picture-in-Picture requires iOS 15+",
        details: nil))
      return
    }
    guard AVPictureInPictureController.isPictureInPictureSupported() else {
      result(FlutterError(
        code: "unsupported",
        message: "Picture-in-Picture is not supported on this device",
        details: nil))
      return
    }
    buildInfrastructureIfNeeded()
    guard hostView != nil, pipController != nil else {
      result(FlutterError(
        code: "unavailable",
        message: "No root view controller to host PiP sample layer",
        details: nil))
      return
    }
    // PiP 需要活跃的音频会话（本 app 音频会话由 Dart audio_session 配置为
    // .playback，这里只确保激活态，不改 category 以免与 just_audio 冲突）。
    try? AVAudioSession.sharedInstance().setActive(true)
    // 先画一帧：layer 无帧时系统不会开窗
    renderFrame()
    requestStart()
    NSLog("[MD3Music] lyrics pip (sampleBuffer) start requested")
    // 已受理；真实激活态由 didStart/didStop -> 'state' 回调回报（不乐观置位）
    result(true)
  }

  // MARK: 开关状态机（start/stop 均为异步指令，快速连点时在途操作未完成
  // 又收到反向指令会让 controller 状态失步；请求只记录意图，终态回调收敛）

  /// 用户请求开启。操作在途时只记录意图，等 didStart/didStop 到达后收敛。
  private func requestStart() {
    switch state {
    case .started:
      notifyState(active: true)
    case .starting, .stopping:
      pendingIntent = true
    case .idle:
      state = .starting
      pendingIntent = true
      // 重试启动：等宿主进层级 + 已画首帧 + isPictureInPicturePossible
      scheduleStartAttempt(attempt: 0)
    }
  }

  /// 用户请求关闭（Dart stop 与点按小窗共用入口）。
  private func requestStop() {
    switch state {
    case .idle:
      notifyState(active: false)
    case .starting:
      startRetry?.cancel()
      pendingIntent = false
      if !awaitingStartCallback {
        // startPictureInPicture 还没真正发出：直接回 idle，不等回调
        state = .idle
        pendingIntent = nil
        notifyState(active: false)
      }
      // 已发出：didStart/failed 到达后由 handleDidStart 收敛执行 stop
    case .started:
      state = .stopping
      pendingIntent = false
      pipController?.stopPictureInPicture()
    case .stopping:
      pendingIntent = false
    }
  }

  /// didStart：进入 started。若在途期间用户已改为要关，立即收敛执行 stop，
  /// 不向 Dart 回报 active:true（最终意图是关）。
  private func handleDidStart() {
    state = .started
    awaitingStartCallback = false
    if pendingIntent == false {
      pendingIntent = nil
      state = .stopping
      pipController?.stopPictureInPicture()
      return
    }
    pendingIntent = nil
    startFrameLoop()
    notifyState(active: true)
  }

  /// didStop（含用户用系统手势划掉小窗）：回 idle。若在途期间用户已改为
  /// 要开，立即收敛执行 start。
  private func handleDidStop() {
    state = .idle
    awaitingStartCallback = false
    stopFrameLoop()
    let wantStart = pendingIntent == true
    pendingIntent = nil
    if wantStart {
      requestStart()
    } else {
      notifyState(active: false)
    }
  }

  /// 启动失败：回 idle 并回报关闭态（真实失败不自动重试，用户可再点）。
  private func handleStartFailed() {
    state = .idle
    awaitingStartCallback = false
    pendingIntent = nil
    stopFrameLoop()
    notifyState(active: false)
  }

  /// 构建 SampleBuffer 式 PiP 基础设施（幂等）。
  /// 离屏宿主视图 + AVSampleBufferDisplayLayer + 双协议代理。
  @available(iOS 15.0, *)
  private func buildInfrastructureIfNeeded() {
    guard pipController == nil else { return }
    guard let rootViewController = keyRootViewController() else {
      NSLog("[MD3Music] lyrics pip no root view controller!")
      return
    }
    // 1. 离屏宿主：layer 必须在窗口层级里 PiP 才会从它取帧；本体移出屏幕不显示
    let host = UIView(frame: CGRect(
      x: -barSize.width - 16, y: -8,
      width: barSize.width, height: barSize.height))
    host.backgroundColor = .clear
    host.isUserInteractionEnabled = false
    rootViewController.view.addSubview(host)
    sampleLayer.videoGravity = .resizeAspect
    sampleLayer.frame = host.bounds
    host.layer.addSublayer(sampleLayer)
    hostView = host

    // 2. controller + 双协议代理（生命周期 + sample buffer 播放控制）
    let lifecycle = LyricsPipLifecycleDelegate()
    lifecycle.onStarted = { [weak self] in
      self?.handleDidStart()
    }
    lifecycle.onWillStop = { [weak self] in
      self?.stopFrameLoop()
    }
    lifecycle.onStopped = { [weak self] in
      self?.handleDidStop()
    }
    lifecycle.onFailed = { [weak self] message in
      NSLog("[MD3Music] lyrics pip failed to start: \(message)")
      self?.handleStartFailed()
    }
    delegateHolder = lifecycle
    let contentSource = AVPictureInPictureController.ContentSource(
      sampleBufferDisplayLayer: sampleLayer,
      playbackDelegate: lifecycle)
    let controller = AVPictureInPictureController(contentSource: contentSource)
    controller.delegate = lifecycle
    controller.requiresLinearPlayback = true
    // 私有样式：去掉播放/暂停/跳过等传输控件，只留系统关闭(X)/还原按钮。
    // responds 检查兜底——API 若被移除，小窗仍可用（多几个用不上的控件）。
    let selector = NSSelectorFromString("setControlsStyle:")
    if controller.responds(to: selector) {
      controller.setValue(1, forKey: "controlsStyle")
    }
    pipController = controller
  }

  private func keyRootViewController() -> UIViewController? {
    let windows = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap { $0.windows }
    let keyWindow = windows.first { $0.isKeyWindow } ?? windows.first
    return keyWindow?.rootViewController
  }

  /// 等"宿主进层级 + 已画首帧 + isPictureInPicturePossible"后再
  /// startPictureInPicture，最多 8 次（0.02/0.12s 间隔）。
  private func scheduleStartAttempt(attempt: Int) {
    guard #available(iOS 15.0, *) else { return }
    startRetry?.cancel()
    let work = DispatchWorkItem { [weak self] in
      guard let self = self, self.state == .starting, self.pendingIntent == true else { return }
      guard let host = self.hostView, let controller = self.pipController else { return }
      guard !controller.isPictureInPictureActive else { return }
      let infraReady = self.hasPainted && host.window != nil
      if infraReady && controller.isPictureInPicturePossible {
        self.awaitingStartCallback = true
        controller.startPictureInPicture()
        return
      }
      if attempt < 8 {
        self.scheduleStartAttempt(attempt: attempt + 1)
      } else {
        NSLog(
          "[MD3Music] lyrics pip start gave up: possible=\(controller.isPictureInPicturePossible), infraReady=\(infraReady)")
        self.state = .idle
        self.pendingIntent = nil
        self.notifyState(active: false)
      }
    }
    startRetry = work
    let delay: DispatchTimeInterval = attempt == 0 ? .milliseconds(20) : .milliseconds(120)
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
  }

  private func stop(result: @escaping FlutterResult) {
    requestStop()
    result(nil)
  }

  private func notifyState(active: Bool) {
    channel?.invokeMethod("state", arguments: ["active": active])
  }

  // MARK: SampleBuffer 帧管线（frameTimer 每帧调用）

  /// 帧驱动：PiP 激活期间 20fps 出帧。用 Timer 而非 CADisplayLink——退后台
  /// （音频后台模式）时 displayLink 随屏幕刷新停摆，Timer 仍持续触发。
  private func startFrameLoop() {
    stopFrameLoop()
    let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
      self?.renderFrame()
    }
    RunLoop.main.add(timer, forMode: .common)
    frameTimer = timer
  }

  private func stopFrameLoop() {
    frameTimer?.invalidate()
    frameTimer = nil
  }

  /// 渲染一帧并入队：@2x 位图上画歌词条 → blit 进 CVPixelBuffer → 包成
  /// CMSampleBuffer enqueue。
  private func renderFrame() {
    guard let sample = makeSample() else { return }
    // failed 态的 renderer 会静默吞帧（表现为画面冻结），先 flush 再入队。
    // sampleBufferRenderer 是 iOS17+；更低版本 layer 本身就是入队口。
    if #available(iOS 17.0, *) {
      let renderer = sampleLayer.sampleBufferRenderer
      if renderer.status == .failed { renderer.flush() }
      renderer.enqueue(sample)
    } else {
      if sampleLayer.status == .failed { sampleLayer.flush() }
      sampleLayer.enqueue(sample)
    }
    hasPainted = true
  }

  private func makeSample() -> CMSampleBuffer? {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 2 // @2x 位图，小窗里文字足够清晰
    format.opaque = true
    let renderer = UIGraphicsImageRenderer(size: barSize, format: format)
    let image = renderer.image { ctx in
      // 渲染器上下文已是 UIKit 左上原点坐标系，与 drawBar 的坐标约定一致
      self.drawBar(in: ctx.cgContext, size: barSize)
    }
    guard let cgImage = image.cgImage else { return nil }

    let pixels = CGSize(width: cgImage.width, height: cgImage.height)
    guard let pool = pixelBufferPool(pixels) else { return nil }
    var buffer: CVPixelBuffer?
    guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer) == kCVReturnSuccess,
          let buffer else { return nil }

    CVPixelBufferLockBaseAddress(buffer, [])
    let drawn = CGContext(
      data: CVPixelBufferGetBaseAddress(buffer),
      width: cgImage.width,
      height: cgImage.height,
      bitsPerComponent: 8,
      bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
        | CGBitmapInfo.byteOrder32Little.rawValue)
    drawn?.draw(cgImage, in: CGRect(origin: .zero, size: pixels))
    CVPixelBufferUnlockBaseAddress(buffer, [])
    guard drawn != nil else { return nil }

    var formatDescription: CMFormatDescription?
    guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: buffer,
            formatDescriptionOut: &formatDescription) == noErr,
          let formatDescription else { return nil }
    // PTS 取 hostTime 当前时刻 + DisplayImmediately：没有 timebase 驱动，
    // 每帧到达即显示。
    var timing = CMSampleTimingInfo(
      duration: .invalid,
      presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
      decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: buffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sample) == noErr,
          let sample else { return nil }
    if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
       CFArrayGetCount(attachments) > 0 {
      let entry = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
      CFDictionarySetValue(
        entry,
        Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
        Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
    }
    return sample
  }

  private func pixelBufferPool(_ size: CGSize) -> CVPixelBufferPool? {
    if let pixelPool, poolSize == size { return pixelPool }
    let attributes: [CFString: Any] = [
      kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
      kCVPixelBufferWidthKey: Int(size.width),
      kCVPixelBufferHeightKey: Int(size.height),
      kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
    ]
    var created: CVPixelBufferPool?
    guard CVPixelBufferPoolCreate(
            kCFAllocatorDefault, nil, attributes as CFDictionary,
            &created) == kCVReturnSuccess,
          let created else { return nil }
    pixelPool = created
    poolSize = size
    return created
  }

  // MARK: 模糊封面背景（切歌/条尺寸变化时后台重出一次）

  /// 帧循环每帧调用：封面指针比对（廉价），变化或条尺寸变了才后台重模糊。
  private func refreshCoverIfNeeded(size: CGSize) {
    guard !coverBlurPending else { return }
    let latest = NowPlayingManager.shared.lastArtworkImage
    let sizeChanged =
      blurredCover != nil && blurredCoverSize != size
    if latest !== coverImage {
      coverImage = latest
      // 旧模糊图保留到新图就绪再替换：模糊后原图不可辨，直接淡替即可；
      // 若先置 nil 回黑底，低遮罩不透明度下会黑↔封面闪烁
      startCoverBlur(latest, size: size)
    } else if sizeChanged {
      startCoverBlur(latest, size: size)
    }
  }

  private func startCoverBlur(_ image: UIImage?, size: CGSize) {
    coverBlurPending = true
    coverQueue.async { [weak self] in
      let blurred = image.flatMap { Self.makeBlurredCover($0, targetSize: size) }
      DispatchQueue.main.async {
        guard let self else { return }
        self.coverBlurPending = false
        // 期间可能又切了歌：只在封面仍是最新的情况下落图，否则下帧重触发
        if let blurred, image === self.coverImage {
          self.blurredCover = blurred
          self.blurredCoverSize = size
        }
        self.renderFrame()
      }
    }
  }

  /// 封面 → 高斯模糊背景图：先按条宽高比 aspect-fill 中心裁到小尺寸，
  /// 小图上做 CIGaussianBlur，绘制时整幅拉伸放大（进一步柔化，代价极低）。
  private static func makeBlurredCover(_ image: UIImage, targetSize: CGSize) -> CGImage? {
    let barAspect = targetSize.width / max(targetSize.height, 1)
    let smallW: CGFloat = 120
    let smallH = max(smallW / max(barAspect, 0.05), 1)
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    let small = UIGraphicsImageRenderer(size: CGSize(width: smallW, height: smallH), format: format)
      .image { _ in
        let imgW = max(image.size.width, 1)
        let imgH = max(image.size.height, 1)
        let scale = max(smallW / imgW, smallH / imgH)
        image.draw(in: CGRect(
          x: (smallW - imgW * scale) / 2,
          y: (smallH - imgH * scale) / 2,
          width: imgW * scale,
          height: imgH * scale))
      }
    guard let ci = CIImage(image: small),
      let filter = CIFilter(name: "CIGaussianBlur")
    else { return nil }
    filter.setValue(ci, forKey: kCIInputImageKey)
    filter.setValue(12.0, forKey: kCIInputRadiusKey)
    guard let out = filter.outputImage else { return nil }
    // 高斯核会向边缘外扩散出透明边，裁回画布尺寸
    let cropped = out.cropped(to: CGRect(x: 0, y: 0, width: smallW, height: smallH))
    return ciContext.createCGImage(cropped, from: cropped.extent)
  }

  // MARK: 卡拉OK绘制（makeSample 的位图上下文调用，UIKit 坐标系）

  /// 在条状画布上绘制一帧：模糊封面背景 + 黑色遮罩（不透明度）+ 底部细
  /// 进度条 + 双行逐字卡拉OK。
  func drawBar(in ctx: CGContext, size: CGSize) {
    let width = size.width
    let height = size.height
    // 底色：sample buffer 视为不透明视频帧，无透明合成对象。有封面时铺
    // 高斯模糊背景（已按条宽高比预裁，直接整幅拉伸），黑色遮罩的 alpha
    // 即设置里的不透明度；无封面时实色黑。
    refreshCoverIfNeeded(size: size)
    if let blurred = blurredCover {
      UIImage(cgImage: blurred).draw(in: CGRect(x: 0, y: 0, width: width, height: height))
      ctx.setFillColor(
        UIColor.black.withAlphaComponent(CGFloat(configOpacity) / 100.0).cgColor)
      ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    } else {
      ctx.setFillColor(UIColor.black.cgColor)
      ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    }

    // 底部细进度条（进度 = 当前位置 / 最后一行结束时间）
    var progress: Double = 0
    if let last = lines.last {
      let totalMs = Double(max(last.start + last.duration, 1))
      progress = min(max(estimatedPositionMs / totalMs, 0), 1)
    }
    let barHeight = max(1.2, height * 0.07)
    ctx.setFillColor(UIColor.white.withAlphaComponent(0.15).cgColor)
    ctx.fill(CGRect(x: 0, y: height - barHeight, width: width, height: barHeight))
    ctx.setFillColor(UIColor.white.withAlphaComponent(0.85).cgColor)
    ctx.fill(CGRect(x: 0, y: height - barHeight, width: CGFloat(progress) * width, height: barHeight))

    // 字号 = 设置字号 × 0.8（18sp → 14.4pt，与原 44pt 条观感一致）；
    // 条高随字号缩放（barSize），文本行始终放得下
    let textAreaHeight = height - barHeight
    let dual = configDoubleLine
    let rowHeight = dual ? textAreaHeight / 2 : textAreaHeight
    let fontSize = CGFloat(configFontSize) * 0.8

    // 占位文案（歌词加载中/暂无歌词/歌词加载失败）：跨两行居中
    if !placeholder.isEmpty {
      let attrs: [NSAttributedString.Key: Any] = [
        .font: UIFont.systemFont(ofSize: fontSize, weight: .medium),
        .foregroundColor: UIColor.white.withAlphaComponent(0.6),
      ]
      let text = placeholder as NSString
      let textSize = text.size(withAttributes: attrs)
      text.draw(
        at: CGPoint(x: (width - textSize.width) / 2, y: (textAreaHeight - textSize.height) / 2),
        withAttributes: attrs)
      return
    }

    // 无当前句：间奏画面（音符符号居中）
    if lineText.isEmpty {
      let attrs: [NSAttributedString.Key: Any] = [
        .font: UIFont.systemFont(ofSize: fontSize * 1.15),
        .foregroundColor: UIColor.white.withAlphaComponent(0.5),
      ]
      let hint = "♪"
      let hintSize = (hint as NSString).size(withAttributes: attrs)
      (hint as NSString).draw(
        at: CGPoint(x: (width - hintSize.width) / 2, y: (textAreaHeight - hintSize.height) / 2),
        withAttributes: attrs)
      return
    }

    // —— 文字蒙版式卡拉OK（对齐安卓 GradientTextView）：整行先画未唱色，
    // 再 clip 已唱宽度重画渐变色层——蒙版右缘 = 已完成字宽累加 + 当前字按
    // 字内播放比例推进，硬边逐字向右扫过；已唱渐变按字 x 位置跨行采样
    //（近似安卓 LinearGradient 0..行宽）。LRC 无逐字：整行渐变不蒙版 ——
    let font = UIFont.systemFont(ofSize: fontSize, weight: .bold)
    let nextFont = UIFont.systemFont(ofSize: fontSize, weight: .regular)
    let horizontalPadding = max(6, width * 0.03)
    let maxWidth = width - horizontalPadding * 2

    let glyphs = layoutBarGlyphs(text: lineText, words: lineWords, font: font)
    let scroll = updatedScrollOffset(
      glyphs: glyphs, words: lineWords, maxWidth: maxWidth, padding: horizontalPadding)
    if !lineWords.isEmpty {
      // 未唱层：整行未唱色
      drawScrollingLine(
        ctx: ctx, glyphs: grayGlyphs(glyphs), font: font,
        rowCenterY: rowHeight * 0.5, rowHeight: rowHeight, width: width,
        scrollOffset: scroll, padding: horizontalPadding)
      // 已唱层：clip 已唱宽度（蒙版右缘随播放右移、随行滚动平移）后重画渐变色
      let sungWidth = sungKaraokeWidth(glyphs: glyphs)
      let edgeX = horizontalPadding - scroll + sungWidth
      if edgeX > 0 {
        ctx.saveGState()
        ctx.clip(to: CGRect(x: 0, y: 0, width: min(edgeX, width), height: height))
        drawScrollingLine(
          ctx: ctx, glyphs: gradientGlyphs(glyphs), font: font,
          rowCenterY: rowHeight * 0.5, rowHeight: rowHeight, width: width,
          scrollOffset: scroll, padding: horizontalPadding)
        ctx.restoreGState()
      }
    } else {
      // LRC/纯文本：整行渐变色（安卓 GradientTextView 的 LRC 路径同款）
      drawScrollingLine(
        ctx: ctx, glyphs: gradientGlyphs(glyphs), font: font,
        rowCenterY: rowHeight * 0.5, rowHeight: rowHeight, width: width,
        scrollOffset: scroll, padding: horizontalPadding)
    }

    if dual, !nextLineText.isEmpty {
      let nextGlyphs = grayGlyphs(
        layoutBarGlyphs(text: nextLineText, words: [], font: nextFont))
      // 副行静态：下一句是未唱预览，超宽右缘裁切即可。不跟随主行滚动——
      // 两者节奏无关，跟着滚会被误读成副行在逐字推进（旧实现 bug）。
      drawScrollingLine(
        ctx: ctx, glyphs: nextGlyphs, font: nextFont,
        rowCenterY: rowHeight * 1.5, rowHeight: rowHeight, width: width,
        scrollOffset: 0, padding: horizontalPadding)
    }
  }

  // MARK: 逐字卡拉OK布局与绘制

  /// 默认配色（configure 未下发前的兜底）：安卓 FloatingLyricService 默认
  /// 渐变 青→紫、未唱灰。
  private static let sungColorStartARGB = 0xFF00E5FF
  private static let sungColorEndARGB = 0xFFFF00FF
  private static let unplayedARGB = 0xFF666666

  private func argbColor(_ argb: Int) -> UIColor {
    UIColor(
      red: CGFloat((argb >> 16) & 0xFF) / 255.0,
      green: CGFloat((argb >> 8) & 0xFF) / 255.0,
      blue: CGFloat(argb & 0xFF) / 255.0,
      alpha: 1.0)
  }

  private func lerpColor(_ a: UIColor, _ b: UIColor, _ t: CGFloat) -> UIColor {
    var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
    var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
    a.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
    b.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
    return UIColor(
      red: r1 + (r2 - r1) * t,
      green: g1 + (g2 - g1) * t,
      blue: b1 + (b2 - b1) * t,
      alpha: a1 + (a2 - a1) * t)
  }

  /// 全量逐字布局：逐字测量宽度（不截断，超宽由 drawScrollingLine 以跑马灯
  /// 滚动呈现）。KRC 有逐字时间轴时按"词"布局（与 lineWords 一一对应，
  /// sungKaraokeWidth/滚动驱动都按下标取词宽）；LRC 纯文本按字布局。
  /// 颜色由调用方分层上色：grayGlyphs（未唱层）/ gradientGlyphs（已唱渐变层）。
  private func layoutBarGlyphs(
    text: String,
    words: [(text: String, start: Int, duration: Int)],
    font: UIFont
  ) -> [(text: String, width: CGFloat, color: UIColor)] {
    var glyphs: [(text: String, width: CGFloat, color: UIColor)] = []
    let attrs: [NSAttributedString.Key: Any] = [.font: font]
    if words.isEmpty {
      for ch in text {
        let s = String(ch)
        glyphs.append((s, (s as NSString).size(withAttributes: attrs).width, .white))
      }
    } else {
      for w in words {
        glyphs.append((w.text, (w.text as NSString).size(withAttributes: attrs).width, .white))
      }
    }
    return glyphs
  }

  /// 未唱层：整行未唱色（设置页配色下发的 unplayedColor）。
  private func grayGlyphs(
    _ glyphs: [(text: String, width: CGFloat, color: UIColor)]
  ) -> [(text: String, width: CGFloat, color: UIColor)] {
    let gray = argbColor(configUnplayedARGB)
    return glyphs.map { ($0.text, $0.width, gray) }
  }

  /// 已唱层配色：整行渐变（gradientStart→gradientEnd）按字 x 位置采样，
  /// 配合已唱区域 clip 形成硬边蒙版——近似安卓 LinearGradient 0..行宽的
  /// 跨行渐变（逐字采样，行滚动时颜色跟字走不漂移）。
  private func gradientGlyphs(
    _ glyphs: [(text: String, width: CGFloat, color: UIColor)]
  ) -> [(text: String, width: CGFloat, color: UIColor)] {
    let start = argbColor(configSungStartARGB)
    let end = argbColor(configSungEndARGB)
    let total = glyphs.reduce(0) { $0 + $1.width }
    guard total > 0 else {
      return glyphs.map { ($0.text, $0.width, start) }
    }
    var x: CGFloat = 0
    return glyphs.map { g in
      let t = min(max((x + g.width / 2) / total, 0), 1)
      x += g.width
      return (g.text, g.width, lerpColor(start, end, t))
    }
  }

  /// 已唱像素宽度（文本空间，蒙版右缘）：已完成字宽累加 + 当前字按字内
  /// 播放比例线性插值（对齐安卓 sungKaraokeWidth 的蒙版推进语义）。
  private func sungKaraokeWidth(
    glyphs: [(text: String, width: CGFloat, color: UIColor)]
  ) -> CGFloat {
    guard !lineWords.isEmpty, glyphs.count == lineWords.count else { return 0 }
    let pos = estimatedPositionMs
    var idx = -1
    for (i, w) in lineWords.enumerated() where pos >= Double(w.start) { idx = i }
    guard idx >= 0 else { return 0 }
    var w: CGFloat = 0
    if idx > 0 {
      for i in 0..<idx { w += glyphs[i].width }
    }
    let word = lineWords[idx]
    if word.duration > 0 {
      let t = min(max((pos - Double(word.start)) / Double(word.duration), 0), 1)
      w += glyphs[idx].width * CGFloat(t)
    } else {
      w += glyphs[idx].width
    }
    return w
  }

  /// 着色前沿驱动的滚动偏移：行首贴左静止；当卡拉OK着色位置接近视口右缘
  /// （超过 72% 宽度）时才向左滚动，让后续未唱的字进入视野，滚到行尾贴右
  /// padding 为止。easeOut 平滑（指数趋近——先快后慢，即 (0,1,1,1) 缓动
  /// 曲线的观感），单向跟随不往返；暂停时着色不动，滚动自然停止。
  private func updatedScrollOffset(
    glyphs: [(text: String, width: CGFloat, color: UIColor)],
    words: [(text: String, start: Int, duration: Int)],
    maxWidth: CGFloat,
    padding: CGFloat
  ) -> CGFloat {
    let now = ProcessInfo.processInfo.systemUptime
    defer { scrollLastUptime = now }
    let total = glyphs.reduce(0) { $0 + $1.width }
    let maxScroll = max(0, total - maxWidth + padding)
    guard maxScroll > 0 else { return 0 }

    // 着色前沿的累计宽度（含正在唱的字）
    var cum: CGFloat = 0
    if !words.isEmpty {
      let pos = estimatedPositionMs
      var idx = -1
      for (i, w) in words.enumerated() where pos >= Double(w.start) { idx = i }
      if idx >= 0 {
        for i in 0...idx { cum += glyphs[i].width }
      }
    } else {
      // LRC 无逐字：按行内播放比例估算着色位置
      if lineStartMs >= 0,
        let li = lines.firstIndex(where: { $0.start == lineStartMs })
      {
        let d = Double(max(lines[li].duration, 1))
        let frac = min(max((estimatedPositionMs - Double(lineStartMs)) / d, 0), 1)
        cum = CGFloat(frac) * total
      }
    }
    // 目标：着色前沿保持在视口 72% 处，越唱越往左带
    let keepAt = maxWidth * 0.72
    let target = min(max(cum - keepAt, 0), maxScroll)
    let dt = scrollLastUptime > 0 ? min(now - scrollLastUptime, 0.2) : 0.016
    scrollOffset += (target - scrollOffset) * CGFloat(1 - exp(-6 * dt))
    return scrollOffset
  }

  /// 单行绘制：x 起点 = padding - scrollOffset，行首贴左；滚出视口的字被
  /// clipsToBounds 裁剪，左右不可见的字剔除不绘制。
  private func drawScrollingLine(
    ctx: CGContext,
    glyphs: [(text: String, width: CGFloat, color: UIColor)],
    font: UIFont,
    rowCenterY: CGFloat,
    rowHeight: CGFloat,
    width: CGFloat,
    scrollOffset: CGFloat,
    padding: CGFloat
  ) {
    guard !glyphs.isEmpty else { return }
    let textHeight = min(font.lineHeight, rowHeight)
    let y = rowCenterY - textHeight / 2
    var x = padding - scrollOffset
    for g in glyphs {
      // 视口剔除：左右不可见的字不绘制
      if x + g.width > 0 && x < width {
        (g.text as NSString).draw(
          at: CGPoint(x: x, y: y),
          withAttributes: [.font: font, .foregroundColor: g.color])
      }
      x += g.width
    }
  }
}

/// PiP 双协议代理：AVPictureInPictureControllerDelegate（生命周期）+
/// AVPictureInPictureSampleBufferPlaybackDelegate（sample buffer 播放控制）。
/// 播放控制按"只读仪表"语义实现——歌词条不是播放器，不响应播放/seek，
/// 仅维持"永远在播"的表象让系统不叠加暂停态。
private final class LyricsPipLifecycleDelegate: NSObject,
    AVPictureInPictureControllerDelegate, AVPictureInPictureSampleBufferPlaybackDelegate {
  var onStarted: () -> Void = {}
  var onWillStop: () -> Void = {}
  var onStopped: () -> Void = {}
  var onFailed: (String) -> Void = { _ in }

  func pictureInPictureControllerWillStartPictureInPicture(
    _ pictureInPictureController: AVPictureInPictureController
  ) {}

  func pictureInPictureControllerDidStartPictureInPicture(
    _ pictureInPictureController: AVPictureInPictureController
  ) {
    onStarted()
  }

  func pictureInPictureControllerWillStopPictureInPicture(
    _ pictureInPictureController: AVPictureInPictureController
  ) {
    onWillStop()
  }

  func pictureInPictureControllerDidStopPictureInPicture(
    _ pictureInPictureController: AVPictureInPictureController
  ) {
    onStopped()
  }

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    failedToStartPictureInPictureWithError error: Error
  ) {
    onFailed(error.localizedDescription)
  }

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
  ) {
    // 小窗系统自带的关闭/还原按钮都走这里：返回 true 让系统把 App 拉回
    // 前台（关闭与最大化均回到 App）。
    completionHandler(true)
  }

  // —— SampleBuffer 播放控制（协议要求的 5 个必选方法 + 1 个可选） ——

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    setPlaying playing: Bool
  ) {}

  func pictureInPictureControllerTimeRangeForPlayback(
    _ pictureInPictureController: AVPictureInPictureController
  ) -> CMTimeRange {
    CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
  }

  func pictureInPictureControllerIsPlaybackPaused(
    _ pictureInPictureController: AVPictureInPictureController
  ) -> Bool {
    false
  }

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    didTransitionToRenderSize newRenderSize: CMVideoDimensions
  ) {}

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    skipByInterval skipInterval: CMTime,
    completion completionHandler: @escaping () -> Void
  ) {
    completionHandler()
  }

  func pictureInPictureControllerShouldProhibitBackgroundAudioPlayback(
    _ pictureInPictureController: AVPictureInPictureController
  ) -> Bool {
    // 音乐就是本 app 在放，绝不能禁止后台音频
    false
  }
}
