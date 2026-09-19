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

// MARK: - iOS 歌词悬浮窗（系统画中画 · VideoCall 式，无系统控件）

/// iOS 歌词悬浮窗：系统画中画（FaceTime 式 VideoCall contentSource，对标
/// GlobalRefresh-PiP 的真机验证方案）。
///
/// 与 Android 的 FloatingLyricService 悬浮窗路径互不影响：本类只在 iOS Runner
/// 内编译，channel 也只由 iOS 端注册。Dart 端对应 lib/core/services/lyrics_pip_service.dart。
///
/// 方案（与被撤实验 8cf877c 的 sample-buffer 帧管线本质不同——没有帧管线就没有黑屏）：
/// - AVPictureInPictureVideoCallViewController 承载自绘歌词条视图，系统直接把
///   该视图合成进 PiP 小窗；PiP 激活期间 App 被系统视作前台，CADisplayLink
///   照常驱动，逐字卡拉OK平滑推进；
/// - VideoCall 式小窗天然没有播放/进度等系统传输控件；controlsStyle KVC 按
///   参照工程收紧（iOS16+ 用 2 / iOS15 用 1），requiresLinearPlayback 兜底；
/// - 点击小窗直接关闭：内容视图上的 Tap 手势 → stopPictureInPicture()，并在
///   restoreUserInterface 回调返回 false，避免把 App 拉回前台；
/// - 启动按参照工程重试：等源视图进层级 + isPictureInPicturePossible 后再
///   startPictureInPicture（最多 8 次，0.02/0.12s 间隔）。
///
/// 渲染：PipLyricBarView.draw 里 NSString/UIFont 画单行细条（300x22pt）。
/// 逐字卡拉OK双色——已唱字按行内索引在 青(0xFF00E5FF)→紫(0xFFFF00FF) 间插值
/// （安卓 FloatingLyricService 默认渐变配色），未唱字灰(0xFF666666)，正在唱的
/// 字按字内比例平滑过渡；超宽截断补省略号；底部细进度条。行进度原生自推进：
/// 以 Dart 最近推送的 positionMs 为锚点 + 本机单调时钟流逝推算，Dart tick 定期校准。

/// 单行卡拉OK条视图：挂在 PiP contentViewController 里，由系统合成进小窗。
final class PipLyricBarView: UIView {
  weak var renderer: LyricsPipManager?
  /// 点击小窗 → 关闭 PiP（参照工程的自定义内容点击关闭交互）
  var onTap: (() -> Void)?
  private var displayLink: CADisplayLink?

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    isOpaque = false
    isUserInteractionEnabled = true
    clipsToBounds = true
    addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap)))
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  /// PiP 激活期间驱动重绘（~20fps 足够逐字卡拉OK平滑；VideoCall PiP 期间
  /// displayLink 后台照常触发，这是参照工程时钟/跑马灯的驱动方式）
  func startAnimating() {
    stopAnimating()
    let link = CADisplayLink(target: self, selector: #selector(handleTick))
    link.preferredFramesPerSecond = 20
    link.add(to: .main, forMode: .common)
    displayLink = link
  }

  func stopAnimating() {
    displayLink?.invalidate()
    displayLink = nil
  }

  @objc private func handleTick() {
    setNeedsDisplay()
  }

  @objc private func handleTap() {
    onTap?()
  }

  override func draw(_ rect: CGRect) {
    // draw(_:) 的 context 已是 UIKit 左上原点坐标系，无需翻转
    guard let ctx = UIGraphicsGetCurrentContext() else { return }
    renderer?.drawBar(in: ctx, size: bounds.size)
  }
}

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
  /// 占位文案（歌词加载中.../暂无歌词/歌词加载失败），空 = 正常渲染行
  private var placeholder = ""

  // 进度锚点：Dart 最近推送的 positionMs + 接收时刻（本机单调钟）
  private var anchorPositionMs: Double = 0
  private var anchorUptime: TimeInterval = 0
  private var playing = false

  private var pipController: AVPictureInPictureController?
  /// VideoCall 式 PiP 的源视图锚点（clear、不交互，挂 App 视图层级）
  private var sourceView: UIView?
  /// PiP 内容控制器（iOS15+ 类，为兼容存基类类型）
  private var contentController: UIViewController?
  private var barView: PipLyricBarView?
  /// controller.delegate 为弱引用，必须自行持有
  private var delegateHolder: AnyObject?
  /// 启动重试（等 isPictureInPicturePossible，参照工程 requestPiPStartWhenReady）
  private var startRetry: DispatchWorkItem?
  private var wantsActive = false
  /// 歌词会话代际（与 Dart LyricsPipService._generation 对齐）：Dart 每次整包
  /// 下发（切歌/新歌词就绪）+1。只接受 generation >= 当前值的更新，迟到的旧歌
  /// setLyrics/setLine/update 直接丢弃，封死快速切歌时的乱序竞态。
  /// 停止（didStop / stop / 点按关闭）时归零，下次开启从 0 重新对齐。
  private var generation = 0
  /// 单行细条尺寸（pt）：对标 GlobalRefresh-PiP 的条状悬浮窗观感
  private static let barSize = CGSize(width: 300, height: 22)

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
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  // MARK: setLyrics（整包歌词下发，切歌/解析完成时一次）

  private func setLyrics(_ args: [String: Any]) {
    let gen = (args["generation"] as? NSNumber)?.intValue ?? 0
    guard gen >= generation else {
      NSLog("[MD3Music] lyrics pip drop stale setLyrics gen=\(gen) current=\(generation)")
      return
    }
    generation = gen
    // 切歌瞬间清空当前行：先画一帧空条（背景 + 进度条归零），旧歌词不在
    // 原生自推进渲染下残留到新歌占位/首行到达。
    lineText = ""
    lineWords = []
    lineStartMs = -1
    placeholder = ""
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
    barView?.setNeedsDisplay()
  }

  // MARK: setLine（当前行 + 逐字时间轴 + 进度校准）

  private func setLine(_ args: [String: Any]) {
    let gen = (args["generation"] as? NSNumber)?.intValue ?? 0
    guard gen >= generation else { return }
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
    barView?.setNeedsDisplay()
  }

  // MARK: update（进度/播放状态校准，间奏与进度条推进用）

  private func update(_ args: [String: Any]) {
    let gen = (args["generation"] as? NSNumber)?.intValue ?? 0
    guard gen >= generation else { return }
    anchorPositionMs = (args["position"] as? NSNumber)?.doubleValue ?? 0
    anchorUptime = ProcessInfo.processInfo.systemUptime
    playing = args["playing"] as? Bool ?? false
    barView?.setNeedsDisplay()
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
    wantsActive = true
    buildInfrastructureIfNeeded()
    guard sourceView != nil, pipController != nil else {
      wantsActive = false
      result(FlutterError(
        code: "unavailable",
        message: "No root view controller to host PiP source view",
        details: nil))
      return
    }
    // PiP 需要活跃的音频会话（本 app 音频会话由 Dart audio_session 配置为
    // .playback，这里只确保激活态，不改 category 以免与 just_audio 冲突）。
    try? AVAudioSession.sharedInstance().setActive(true)
    restoreBarForOpening()
    // 按参照工程重试启动：等源视图进层级 + isPictureInPicturePossible
    scheduleStartAttempt(attempt: 0)
    NSLog("[MD3Music] lyrics pip (videoCall) start requested")
    // 乐观返回；最终激活态由 delegate didStart/didStop -> 'state' 回调校正
    result(true)
  }

  /// 构建 VideoCall 式 PiP 基础设施（幂等）。参照 GlobalRefresh-PiP 的 setupPip：
  /// 源视图（宽高比锚点）+ AVPictureInPictureVideoCallViewController（自绘内容）
  /// + ContentSource(activeVideoCallSourceView:contentViewController:)。
  @available(iOS 15.0, *)
  private func buildInfrastructureIfNeeded() {
    guard pipController == nil else { return }
    guard let rootViewController = keyRootViewController() else {
      NSLog("[MD3Music] lyrics pip no root view controller!")
      return
    }
    // 1. 源视图：PiP 窗口宽高比跟随它；clear、不交互、无可见内容
    let source = UIView(frame: CGRect(origin: .zero, size: Self.barSize))
    source.backgroundColor = .clear
    source.isOpaque = false
    source.isUserInteractionEnabled = false
    source.clipsToBounds = true
    rootViewController.view.addSubview(source)
    sourceView = source

    // 2. 内容控制器：承载歌词条，PiP 小窗直接显示它（无系统播放控件）
    let content = AVPictureInPictureVideoCallViewController()
    content.preferredContentSize = Self.barSize
    content.view.backgroundColor = .clear
    content.view.isOpaque = false
    content.view.layer.backgroundColor = UIColor.clear.cgColor
    content.view.clipsToBounds = true
    let bar = PipLyricBarView(frame: content.view.bounds)
    bar.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    bar.renderer = self
    bar.onTap = { [weak self] in
      self?.closeFromTap()
    }
    content.view.addSubview(bar)
    barView = bar
    contentController = content

    // 3. controller + 生命周期 delegate + 无控件样式
    let contentSource = AVPictureInPictureController.ContentSource(
      activeVideoCallSourceView: source,
      contentViewController: content)
    let controller = AVPictureInPictureController(contentSource: contentSource)
    let lifecycle = LyricsPipLifecycleDelegate()
    lifecycle.onStarted = { [weak self] in
      self?.restoreBarForOpening()
      self?.barView?.setNeedsDisplay()
      self?.barView?.startAnimating()
      self?.notifyState(active: true)
    }
    lifecycle.onWillStop = { [weak self] in
      self?.barView?.stopAnimating()
    }
    lifecycle.onStopped = { [weak self] in
      self?.barView?.stopAnimating()
      self?.restoreBarForOpening()
      self?.generation = 0
      self?.notifyState(active: false)
    }
    lifecycle.onFailed = { [weak self] message in
      NSLog("[MD3Music] lyrics pip failed to start: \(message)")
      self?.wantsActive = false
      self?.barView?.stopAnimating()
      self?.notifyState(active: false)
    }
    delegateHolder = lifecycle
    controller.delegate = lifecycle
    applyNoControlsStyle(to: controller)
    controller.requiresLinearPlayback = true
    controller.canStartPictureInPictureAutomaticallyFromInline = false
    pipController = controller
  }

  private func keyRootViewController() -> UIViewController? {
    let windows = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap { $0.windows }
    let keyWindow = windows.first { $0.isKeyWindow } ?? windows.first
    return keyWindow?.rootViewController
  }

  /// 去掉小窗上的系统控件：controlsStyle KVC（参照工程同款，iOS16+ 用 2，
  /// iOS15 用 1），requiresLinearPlayback 兜底禁用快进/快退。
  private func applyNoControlsStyle(to controller: AVPictureInPictureController) {
    let style: Int
    if #available(iOS 16.0, *) {
      style = 2
    } else {
      style = 1
    }
    controller.setValue(style, forKey: "controlsStyle")
  }

  /// 参照工程 requestPiPStartWhenReady：源视图进层级且 isPictureInPicturePossible
  /// 才 startPictureInPicture，最多 8 次（0.02/0.12s 间隔）。
  private func scheduleStartAttempt(attempt: Int) {
    guard #available(iOS 15.0, *) else { return }
    startRetry?.cancel()
    let work = DispatchWorkItem { [weak self] in
      guard let self = self, self.wantsActive else { return }
      guard let source = self.sourceView, let controller = self.pipController else { return }
      guard !controller.isPictureInPictureActive else { return }
      let sourceReady = !source.bounds.isEmpty && source.window != nil
      if sourceReady && controller.isPictureInPicturePossible {
        controller.startPictureInPicture()
        return
      }
      if attempt < 8 {
        self.scheduleStartAttempt(attempt: attempt + 1)
      } else {
        NSLog(
          "[MD3Music] lyrics pip start gave up: possible=\(controller.isPictureInPicturePossible), sourceReady=\(sourceReady)")
        self.wantsActive = false
        self.notifyState(active: false)
      }
    }
    startRetry = work
    let delay: DispatchTimeInterval = attempt == 0 ? .milliseconds(20) : .milliseconds(120)
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
  }

  private func stop(result: @escaping FlutterResult) {
    wantsActive = false
    startRetry?.cancel()
    startRetry = nil
    generation = 0
    if #available(iOS 15.0, *) {
      if let controller = pipController, controller.isPictureInPictureActive {
        hideBarForClosing()
        controller.stopPictureInPicture()
      } else {
        hideBarForClosing()
        notifyState(active: false)
      }
    }
    result(nil)
  }

  /// 点击小窗关闭（无系统控件，参照工程 handlePiPContentTap 的交互）
  private func closeFromTap() {
    wantsActive = false
    startRetry?.cancel()
    startRetry = nil
    generation = 0
    if #available(iOS 15.0, *),
      let controller = pipController, controller.isPictureInPictureActive {
      hideBarForClosing()
      controller.stopPictureInPicture()
      return
    }
    notifyState(active: false)
  }

  /// 关闭前把内容与源视图藏起来（参照工程 hidePiPContentForClosing /
  /// movePiPSourceViewOffscreenForClosing），避免关闭动画闪烁。
  private func hideBarForClosing() {
    guard let source = sourceView else { return }
    UIView.performWithoutAnimation {
      barView?.layer.removeAllAnimations()
      barView?.alpha = 0.01
      barView?.layer.opacity = 0
      source.frame = CGRect(x: -8, y: -8, width: 1, height: 1)
      source.superview?.layoutIfNeeded()
      CATransaction.flush()
    }
  }

  /// 启动/恢复内容可见性与源视图尺寸（参照工程 restorePiPVisualSurfaces）
  private func restoreBarForOpening() {
    guard let source = sourceView else { return }
    UIView.performWithoutAnimation {
      source.frame = CGRect(origin: .zero, size: Self.barSize)
      barView?.alpha = 1
      barView?.layer.opacity = 1
      contentController?.preferredContentSize = Self.barSize
      source.superview?.layoutIfNeeded()
    }
  }

  private func notifyState(active: Bool) {
    channel?.invokeMethod("state", arguments: ["active": active])
  }

  // MARK: 单行卡拉OK绘制（PipLyricBarView.draw 调用，UIKit 坐标系）

  /// 在条状画布上绘制一帧：半透明黑背景 + 底部细进度条 + 单行逐字卡拉OK。
  func drawBar(in ctx: CGContext, size: CGSize) {
    let width = size.width
    let height = size.height
    // 半透明黑背景
    ctx.setFillColor(UIColor(white: 0.0, alpha: 0.75).cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

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

    // 字号随条高自适应（22pt 条 ≈ 13.6pt 字）
    let fontSize = min(max(height * 0.62, 10), 18)

    // 占位文案（歌词加载中/暂无歌词/歌词加载失败）
    if !placeholder.isEmpty {
      let attrs: [NSAttributedString.Key: Any] = [
        .font: UIFont.systemFont(ofSize: fontSize, weight: .medium),
        .foregroundColor: UIColor.white.withAlphaComponent(0.6),
      ]
      let text = placeholder as NSString
      let textSize = text.size(withAttributes: attrs)
      text.draw(
        at: CGPoint(x: (width - textSize.width) / 2, y: (height - textSize.height) / 2),
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
        at: CGPoint(x: (width - hintSize.width) / 2, y: (height - hintSize.height) / 2),
        withAttributes: attrs)
      return
    }

    // —— 单行逐字卡拉OK：左侧起排，超宽截断加省略号，垂直居中 ——
    let font = UIFont.systemFont(ofSize: fontSize, weight: .bold)
    let horizontalPadding = max(6, width * 0.03)
    let maxWidth = width - horizontalPadding * 2
    let glyphs = layoutBarGlyphs(
      text: lineText, words: lineWords, positionMs: estimatedPositionMs,
      maxWidth: maxWidth, font: font)
    let textHeight = min(font.lineHeight, height - barHeight)
    let y = (height - barHeight - textHeight) / 2
    var x = horizontalPadding
    for g in glyphs {
      (g.text as NSString).draw(
        at: CGPoint(x: x, y: y),
        withAttributes: [.font: font, .foregroundColor: g.color])
      x += g.width
    }
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

/// PiP 生命周期代理：iOS15+ 的 AVPictureInPictureControllerDelegate。
/// VideoCall 式不需要 AVPictureInPictureSampleBufferPlaybackDelegate——
/// 没有播放控制协议，也就没有系统传输控件。
private final class LyricsPipLifecycleDelegate: NSObject, AVPictureInPictureControllerDelegate {
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
    // 点击小窗关闭时绝不能把 App 拉回前台（参照工程同款 completionHandler(false)）
    completionHandler(false)
  }
}
