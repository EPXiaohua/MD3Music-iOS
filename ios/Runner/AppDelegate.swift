import Flutter
import UIKit
import PhotosUI
import UniformTypeIdentifiers
import MediaPlayer
import AVFoundation
import AVKit
import CoreMedia

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate,
    UIDocumentPickerDelegate, PHPickerViewControllerDelegate {
  /// 待回复的 FlutterResult（两个选择器互斥，同一时间只允许一个）
  private var pendingResult: FlutterResult?
  private var channelsConfigured = false

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

    // iOS 锁屏/控制中心 Now Playing 信息与远程命令。
    // Android 的锁屏/通知由 Media3 MediaSession 负责，不经过此 channel，
    // 本 channel 仅在 iOS Runner 内注册，互不影响。
    NowPlayingManager.shared.attach(messenger: messenger)

    // iOS 歌词悬浮窗（系统画中画）。Android 悬浮歌词走 FloatingLyricService，
    // 本 channel 仅在 iOS Runner 内注册，互不影响。
    LyricsPipManager.shared.attach(messenger: messenger)

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

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    guard let result = pendingResult else { return }
    pendingResult = nil
    guard let src = urls.first else {
      result(nil)
      return
    }
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
    result(nil)
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
      if let uri = artUri, uri == self.appliedArtUri { return }
      self.appliedArtUri = artUri
      self.artworkRequestId += 1
      let requestId = self.artworkRequestId
      guard let uri = artUri, !uri.isEmpty, let url = URL(string: uri) else {
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

// MARK: - iOS 歌词悬浮窗（Picture-in-Picture + AVSampleBufferDisplayLayer）

/// iOS 歌词悬浮窗桥接：把卡拉OK歌词渲染进系统 PiP 窗口（对标 Android FloatingLyricService）。
///
/// 与 Android 的 FloatingLyricService 悬浮窗路径互不影响：本类只在 iOS Runner
/// 内编译，channel 也只由 iOS 端注册。Dart 端对应 lib/core/services/lyrics_pip_service.dart。
///
/// 帧流保活（继承 8cf877c 实验的黑屏教训）：
/// 1. isPlaybackPaused 恒 false——歌词窗是常显内容，系统按"暂停"语义冻结
///    图层时序后帧 PTS 永远等不到呈现时刻 → 黑屏；
/// 2. controlTimebase 每次 送帧/收进度 都拉回 hostTime，rate 恒 1.0——
///    rate 跟随播放置 0 会被 LayerSync 冻结 → 黑屏；timebase 长期漂移
///    落后于帧 PTS → 冻结卡屏；
/// 3. PiP 激活期间 0.25s 周期补帧（后台靠 audio 后台模式 + 音频会话活跃保活），
///    单帧入队可能不被系统提交显示，持续心跳同时驱动逐字卡拉OK自推进；
/// 4. 帧 PTS = hostTime + 0.1s 余量，即使 timebase 被短暂冻结也能立即追上；
/// 5. enqueue 失败（status == .failed）flush 后重试一次。
///
/// 渲染：CoreGraphics 把歌词画进 600x44 BGRA 位图（单行细条，300x22pt @2x）。
/// 逐字卡拉OK双色——已唱字按行内索引在 青(0xFF00E5FF)→紫(0xFFFF00FF) 间插值
/// （安卓 FloatingLyricService 默认渐变配色），未唱字灰(0xFF666666)，正在唱的
/// 字按字内比例平滑过渡；超宽截断补省略号；底部 2px 进度条。行进度原生自推进：
/// 以 Dart 最近推送的 positionMs 为锚点 + 本机单调时钟流逝推算，Dart tick 定期校准。
final class LyricsPipManager: NSObject {
  static let shared = LyricsPipManager()

  private var channel: FlutterMethodChannel?
  /// 整包歌词（按时间升序）：副行"下一句"与顶部进度条总长用
  private var lines: [(start: Int, duration: Int, text: String, translation: String?)] = []

  // 当前句（Dart 行切换时推送 setLine）
  private var lineText = ""
  private var lineWords: [(text: String, start: Int, duration: Int)] = []
  /// 当前行 startMs：在整包 lines 里定位 index，供副行取下一句
  private var lineStartMs = -1
  /// 占位文案（歌词加载中.../暂无歌词/歌词加载失败），空 = 正常渲染行
  private var placeholder = ""

  // 进度锚点：Dart 最近推送的 positionMs + 接收时刻（本机单调钟）
  private var anchorPositionMs: Double = 0
  private var anchorUptime: TimeInterval = 0
  private var playing = false

  /// 帧时钟：PTS 与它的当前时间对齐后帧才会被立即呈现
  private var controlTimebase: CMTimebase?
  /// PiP 激活期间的补帧心跳（驱动逐字推进 + 保证流不断）
  private var frameTimer: Timer?
  private var pipController: AVPictureInPictureController?
  private var displayLayer: AVSampleBufferDisplayLayer?
  /// controller.delegate 为弱引用，必须自行持有
  private var playbackDelegateHolder: AnyObject?

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
        if #available(iOS 15.0, *) {
          self.pipController?.stopPictureInPicture()
        }
        result(nil)
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
    renderAndEnqueue()
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
    renderAndEnqueue()
  }

  // MARK: update（进度/播放状态校准，间奏与进度条推进用）

  private func update(_ args: [String: Any]) {
    anchorPositionMs = (args["position"] as? NSNumber)?.doubleValue ?? 0
    anchorUptime = ProcessInfo.processInfo.systemUptime
    playing = args["playing"] as? Bool ?? false
    renderAndEnqueue()
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
    if pipController == nil {
      let layer = AVSampleBufferDisplayLayer()
      // 单行悬浮条帧尺寸：600x44 px ≙ 300x22 pt（@2x），对标
      // GlobalRefresh-PiP 的 compact 悬浮条与安卓单行悬浮歌词观感；
      // 背景交给每帧自绘的半透明黑，layer 本底透明
      layer.bounds = CGRect(x: 0, y: 0, width: 600, height: 44)
      layer.backgroundColor = UIColor(white: 0, alpha: 0).cgColor
      // PiP 要求 sampleBuffer layer 已挂进视图层级，否则 startPictureInPicture
      // 会被系统静默忽略。挂到 keyWindow 根层并移到屏幕外，避免遮挡 App 界面。
      let windows = UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .flatMap { $0.windows }
      if let rootLayer = (windows.first { $0.isKeyWindow } ?? windows.first)?
        .rootViewController?.view.layer {
        layer.position = CGPoint(x: -10000, y: -10000)
        rootLayer.addSublayer(layer)
        NSLog("[MD3Music] lyrics pip layer attached")
      } else {
        NSLog("[MD3Music] lyrics pip no root layer!")
      }
      // 帧时钟：hostTime 派生的 timebase。新建 timebase 时间从 0 起算，而帧 PTS
      // 是 hostTime，不对齐帧永远不显示（2d2d074 教训）。
      if let tb = try? CMTimebase(sourceClock: CMClock.hostTimeClock) {
        CMTimebaseSetTime(tb, time: CMClock.hostTimeClock.time)
        CMTimebaseSetRate(tb, rate: 1.0)
        layer.controlTimebase = tb
        controlTimebase = tb
      }
      let delegate = PipPlaybackDelegate()
      // PiP 窗口播放/暂停按钮 → 回传 Dart 切换播放（Dart 播完经 update 回流状态）
      delegate.onSetPlaying = { [weak self] value in
        self?.playing = value
        self?.anchorUptime = ProcessInfo.processInfo.systemUptime
        self?.channel?.invokeMethod(
          "command", arguments: ["action": "pipPlayPause", "playing": value])
      }
      delegate.onStarted = { [weak self] in
        self?.startFrameTimer()
        self?.notifyState(active: true)
      }
      delegate.onStopped = { [weak self] in
        self?.stopFrameTimer()
        self?.notifyState(active: false)
      }
      delegate.onRenderSizeChange = { [weak self] in
        self?.renderAndEnqueue()
      }
      let source = AVPictureInPictureController.ContentSource(
        sampleBufferDisplayLayer: layer,
        playbackDelegate: delegate)
      let controller = AVPictureInPictureController(contentSource: source)
      controller.delegate = delegate
      controller.canStartPictureInPictureAutomaticallyFromInline = false
      displayLayer = layer
      playbackDelegateHolder = delegate
      pipController = controller
    }
    // PiP 需要活跃的音频会话（本 app 音频会话由 Dart audio_session 配置，
    // 这里只确保激活态，不改 category 以免与 just_audio 冲突）。
    try? AVAudioSession.sharedInstance().setActive(true)
    // 启动时立即渲染首帧（用最近推送的进度），让窗口出现即有内容
    renderAndEnqueue()
    pipController?.startPictureInPicture()
    NSLog("[MD3Music] lyrics pip start requested")
    result(true)
  }

  private func notifyState(active: Bool) {
    channel?.invokeMethod("state", arguments: ["active": active])
  }

  // MARK: 补帧心跳（PiP 激活期间 0.25s 一帧）

  private func startFrameTimer() {
    stopFrameTimer()
    let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
      self?.renderAndEnqueue()
    }
    // .common 模式：PiP 前台显示期间不允许被主线程长任务饿出卡顿
    RunLoop.main.add(timer, forMode: .common)
    frameTimer = timer
  }

  private func stopFrameTimer() {
    frameTimer?.invalidate()
    frameTimer = nil
  }

  // MARK: 帧管线

  private func renderAndEnqueue() {
    guard #available(iOS 15.0, *) else { return }
    guard let layer = displayLayer, pipController != nil else { return }
    // 每帧都把 timebase 拉回 hostTime 并保持 rate 1.0（8cf877c 黑屏教训：
    // rate 跟随播放置 0 → LayerSync 冻结 → 黑屏；timebase 漂移 → 卡屏）
    if let tb = controlTimebase {
      CMTimebaseSetTime(tb, time: CMClock.hostTimeClock.time)
      CMTimebaseSetRate(tb, rate: 1.0)
    }
    // 队列积压时跳过本帧，防卡帧（0.25s 心跳下积压只会出现在系统短暂挂起后）
    guard layer.isReadyForMoreMediaData else { return }

    let width = 600
    let height = 44
    var pixelBuffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
      kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
    guard status == kCVReturnSuccess, let pb = pixelBuffer else { return }

    CVPixelBufferLockBaseAddress(pb, [])
    let drawn = drawFrame(pixelBuffer: pb, width: CGFloat(width), height: CGFloat(height))
    CVPixelBufferUnlockBaseAddress(pb, [])
    guard drawn else { return }

    var formatDesc: CMVideoFormatDescription?
    guard CMVideoFormatDescriptionCreateForImageBuffer(
      allocator: kCFAllocatorDefault,
      imageBuffer: pb,
      formatDescriptionOut: &formatDesc) == noErr,
      let format = formatDesc else { return }

    enqueue(pixelBuffer: pb, formatDescription: format, layer: layer)
    if layer.status == .failed {
      // 偶发渲染失败：flush 一次后重试（0a14dbb 教训：单帧失败后流会断）
      layer.flush()
      enqueue(pixelBuffer: pb, formatDescription: format, layer: layer)
    }
  }

  private func enqueue(
    pixelBuffer: CVPixelBuffer,
    formatDescription: CMVideoFormatDescription,
    layer: AVSampleBufferDisplayLayer
  ) {
    // PTS = hostTime + 0.1s 余量：帧的呈现时刻永远略超前 timebase 当前值，
    // 即使 timebase 被系统短暂冻结也能在恢复后立即追上显示
    let hostTime = CMClock.hostTimeClock.time
    let pts = CMTime(
      value: hostTime.value + Int64(hostTime.timescale) / 10,
      timescale: hostTime.timescale)
    var timing = CMSampleTimingInfo(
      duration: CMTime.invalid,
      presentationTimeStamp: pts,
      decodeTimeStamp: CMTime.invalid)
    var sampleBuffer: CMSampleBuffer?
    let status = CMSampleBufferCreateForImageBuffer(
      allocator: kCFAllocatorDefault,
      imageBuffer: pixelBuffer,
      dataReady: true,
      makeDataReadyCallback: nil,
      refcon: nil,
      formatDescription: formatDescription,
      sampleTiming: &timing,
      sampleBufferOut: &sampleBuffer)
    guard status == noErr, let sb = sampleBuffer else { return }
    layer.enqueue(sb)
  }

  /// 在位图上绘制一帧。返回是否绘制成功。
  private func drawFrame(pixelBuffer: CVPixelBuffer, width: CGFloat, height: CGFloat) -> Bool {
    guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return false }
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return false }
    guard let ctx = CGContext(
      data: base,
      width: Int(width),
      height: Int(height),
      bitsPerComponent: 8,
      bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
      space: colorSpace,
      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        | CGBitmapInfo.byteOrder32Little.rawValue
    ) else { return false }

    // raw CGBitmapContext 默认 y 轴向上，先翻转成 UIKit 的左上原点坐标系，
    // 文本/填充才能按常规 UIKit 语义绘制（否则整帧上下颠倒）
    ctx.translateBy(x: 0, y: height)
    ctx.scaleBy(x: 1.0, y: -1.0)
    UIGraphicsPushContext(ctx)
    defer { UIGraphicsPopContext() }

    // 半透明黑背景
    ctx.setFillColor(UIColor(white: 0.0, alpha: 0.75).cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

    // 底部 2px 细进度条（进度 = 当前位置 / 最后一行结束时间）
    var progress: Double = 0
    if let last = lines.last {
      let totalMs = Double(max(last.start + last.duration, 1))
      progress = min(max(estimatedPositionMs / totalMs, 0), 1)
    }
    let barHeight: CGFloat = 2
    ctx.setFillColor(UIColor.white.withAlphaComponent(0.15).cgColor)
    ctx.fill(CGRect(x: 0, y: height - barHeight, width: width, height: barHeight))
    ctx.setFillColor(UIColor.white.withAlphaComponent(0.85).cgColor)
    ctx.fill(CGRect(x: 0, y: height - barHeight, width: CGFloat(progress) * width, height: barHeight))

    // 占位文案（歌词加载中/暂无歌词/歌词加载失败）
    if !placeholder.isEmpty {
      let attrs: [NSAttributedString.Key: Any] = [
        .font: UIFont.systemFont(ofSize: 20, weight: .medium),
        .foregroundColor: UIColor.white.withAlphaComponent(0.6),
      ]
      let size = (placeholder as NSString).size(withAttributes: attrs)
      (placeholder as NSString).draw(
        at: CGPoint(x: (width - size.width) / 2, y: (height - size.height) / 2),
        withAttributes: attrs)
      return true
    }

    let positionMs = estimatedPositionMs
    // 无当前句：间奏画面（音符符号居中）
    if lineText.isEmpty {
      let attrs: [NSAttributedString.Key: Any] = [
        .font: UIFont.systemFont(ofSize: 22),
        .foregroundColor: UIColor.white.withAlphaComponent(0.5),
      ]
      let hint = "♪"
      let size = (hint as NSString).size(withAttributes: attrs)
      (hint as NSString).draw(
        at: CGPoint(x: (width - size.width) / 2, y: (height - size.height) / 2),
        withAttributes: attrs)
      return true
    }

    // —— 单行逐字卡拉OK：左侧起排，超宽截断加省略号，垂直居中 ——
    let font = UIFont.systemFont(ofSize: 28, weight: .bold)
    let horizontalPadding: CGFloat = 20
    let maxWidth = width - horizontalPadding * 2
    let glyphs = layoutBarGlyphs(
      text: lineText, words: lineWords, positionMs: positionMs,
      maxWidth: maxWidth, font: font)
    let lineH = font.lineHeight
    let y = (height - lineH) / 2
    var x = horizontalPadding
    for g in glyphs {
      (g.text as NSString).draw(
        at: CGPoint(x: x, y: y),
        withAttributes: [.font: font, .foregroundColor: g.color])
      x += g.width
    }
    return true
  }

  // MARK: 逐字卡拉OK布局与绘制

  /// 安卓 FloatingLyricService 默认配色：已唱 青→紫 渐变（按字索引在行内插值），
  /// 未唱 灰。正在唱的字按字内比例在灰与已唱色之间过渡。
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

  /// 第 i 字的"已唱"色：行内索引在 青→紫 间线性插值
  private func sungColor(at index: Int, wordCount: Int) -> UIColor {
    guard wordCount > 1 else { return argbColor(Self.sungColorStartARGB) }
    let t = CGFloat(index) / CGFloat(wordCount - 1)
    return lerpColor(
      argbColor(Self.sungColorStartARGB),
      argbColor(Self.sungColorEndARGB),
      t)
  }

  /// 第 i 字在 positionMs 时刻的颜色：未唱灰 / 已唱渐变色 / 当前字按字内比例过渡
  private func wordColor(index: Int, word: (text: String, start: Int, duration: Int),
      wordCount: Int, positionMs: Double) -> UIColor {
    let unplayed = argbColor(Self.unplayedARGB)
    let sung = sungColor(at: index, wordCount: wordCount)
    guard word.duration > 0 else {
      return positionMs >= Double(word.start) ? sung : unplayed
    }
    let t = CGFloat((positionMs - Double(word.start)) / Double(word.duration))
    if t <= 0 { return unplayed }
    if t >= 1 { return sung }
    return lerpColor(unplayed, sung, t)
  }

  /// 单行条状布局：逐字测量宽度并上色，总宽超限时截断并补灰色省略号。
  private func layoutBarGlyphs(
    text: String,
    words: [(text: String, start: Int, duration: Int)],
    positionMs: Double,
    maxWidth: CGFloat,
    font: UIFont
  ) -> [(text: String, width: CGFloat, color: UIColor)] {
    var glyphs: [(text: String, width: CGFloat, color: UIColor)] = []
    let attrs: [NSAttributedString.Key: Any] = [.font: font]
    if words.isEmpty {
      // LRC/纯文本无逐字时间轴：整行白字
      for ch in text {
        let s = String(ch)
        glyphs.append((s, (s as NSString).size(withAttributes: attrs).width, .white))
      }
    } else {
      for (i, w) in words.enumerated() {
        glyphs.append((
          w.text,
          (w.text as NSString).size(withAttributes: attrs).width,
          wordColor(index: i, word: w, wordCount: words.count, positionMs: positionMs)))
      }
    }
    let total = glyphs.reduce(0) { $0 + $1.width }
    if total <= maxWidth { return glyphs }
    // 截断：给末尾省略号留位
    let ellipsisW = ("…" as NSString).size(withAttributes: attrs).width
    var out: [(text: String, width: CGFloat, color: UIColor)] = []
    var x: CGFloat = 0
    for g in glyphs {
      if x + g.width > maxWidth - ellipsisW { break }
      out.append(g)
      x += g.width
    }
    out.append(("…", ellipsisW, argbColor(Self.unplayedARGB)))
    return out
  }
}

/// iOS 15+ PiP sample-buffer 播放代理：转发系统播放控制到 LyricsPipManager。
@available(iOS 15.0, *)
private final class PipPlaybackDelegate: NSObject,
    AVPictureInPictureSampleBufferPlaybackDelegate, AVPictureInPictureControllerDelegate {
  /// PiP 窗口播放/暂停按钮 → 回传 Dart
  var onSetPlaying: (Bool) -> Void = { _ in }
  var onStarted: () -> Void = {}
  var onStopped: () -> Void = {}
  /// 用户缩放 PiP 窗口 → manager 重绘适配新尺寸
  var onRenderSizeChange: () -> Void = {}

  func pictureInPictureControllerIsPlaybackPaused(
    _ pictureInPictureController: AVPictureInPictureController
  ) -> Bool {
    // 歌词悬浮窗是常显内容（不是视频），永远不能让系统按"暂停"
    // 语义冻结图层时序——否则 LayerSync 会 pause，帧 PTS 永远等
    // 不到呈现时刻 → 黑屏（8cf877c 教训）。暂停语义由 Dart 停推进度体现。
    return false
  }

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    setPlaying playing: Bool
  ) {
    onSetPlaying(playing)
  }

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    skipByInterval skipInterval: CMTime,
    completion completionHandler: @escaping () -> Void
  ) {
    // 歌词悬浮窗不支持快进/快退
    completionHandler()
  }

  func pictureInPictureControllerTimeRangeForPlayback(
    _ pictureInPictureController: AVPictureInPictureController
  ) -> CMTimeRange {
    // 必须返回非空区间，否则 PiP 判定"无可播放内容"一直转圈（401308c 教训）。
    // 歌词按流式推送没有总时长，给当前时刻起的一段长区间即可。
    let now = CMClock.hostTimeClock.time
    let start = CMTime(
      value: now.value - Int64(now.timescale),
      timescale: now.timescale)
    return CMTimeRange(start: start, duration: CMTime(seconds: 3600, preferredTimescale: 600))
  }

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    didTransitionToRenderSize newRenderSize: CMVideoDimensions
  ) {
    // 用户缩放窗口后重绘一帧适配新尺寸
    onRenderSizeChange()
  }

  func pictureInPictureControllerDidStartPictureInPicture(
    _ pictureInPictureController: AVPictureInPictureController
  ) {
    onStarted()
  }

  func pictureInPictureControllerDidStopPictureInPicture(
    _ pictureInPictureController: AVPictureInPictureController
  ) {
    onStopped()
  }
}
