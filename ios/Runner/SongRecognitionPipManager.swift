import AVFoundation
import AVKit
import Flutter
import UIKit

// MARK: - iOS 听歌识曲悬浮窗（系统画中画 · SampleBuffer 帧管线）

/// iOS 听歌识曲悬浮窗：系统画中画，SampleBuffer contentSource + 自绘帧管线。
/// 帧管线与歌词悬浮窗（LyricsPipManager）同一套方案：
/// - 离屏宿主视图挂 AVSampleBufferDisplayLayer 保持窗口层级，CVPixelBufferPool
///   出帧（UIGraphicsImageRenderer @2x 位图 blit），hostTime PTS +
///   DisplayImmediately，iOS17+ 走 sampleBufferRenderer（failed 态先 flush）；
/// - 主线程 Timer 50ms（20fps）驱动——退后台（音频后台模式）时 displayLink
///   随屏幕刷新停摆，Timer 仍持续出帧；
/// - setControlsStyle KVC(1) 只留系统关闭(X)/还原按钮，requiresLinearPlayback 兜底；
/// - 启动重试 8 次，等"宿主进层级 + 首帧 + isPictureInPicturePossible"。
///
/// 与歌词窗的差异：
/// - 窗口为 2:1 横向（300x150pt @2x 位图 600x300）：左侧麦克风圆标 + 右侧
///   状态文案；状态机（idle/listening/recognizing/result/stopped）由 Dart 识别
///   循环经 update 推送。iOS 无系统音频捕获能力，识别音频走麦克风（Dart 侧
///   录音，与识曲页同一链路），原生不采集任何音频；
/// - 聆听中：麦克风圆标变红 + 红色边缘发光 + 1.0→1.15 脉冲缩放（对齐识曲页
///   录音态动效）；结果态圆标变 primaryContainer 并显示对勾；
/// - 轻点窗口浮现系统按钮，还原按钮回调 restore 通知 Dart（重新开始识别
///   循环，用于结果/未识别后再次识别）；PiP 随还原操作关闭后由 Dart 稍候
///   重开，小窗因此常驻；点关闭(X)则原生回报关闭态，Dart 结束悬浮模式并
///   停止识别。Dart 开窗后会立即开始识别循环（悬浮窗内部不可点，识别
///   不依赖窗口交互）。
///
/// Dart 端对应 lib/modules/recognition/pip_recognition_controller.dart。

final class SongRecognitionPipManager: NSObject {
  static let shared = SongRecognitionPipManager()

  private var channel: FlutterMethodChannel?

  // —— 窗口内容状态（Dart update 推送）——
  /// idle=点击开始听歌识曲 / listening=正在聆听 / recognizing=正在识别第N段 /
  /// result=识别结果 / stopped=已停止识别
  private var state = "idle"
  private var hintText = "点击开始听歌识曲"
  private var songName = ""
  private var artist = ""

  // —— SampleBuffer 帧管线 ——
  private let sampleLayer = AVSampleBufferDisplayLayer()
  /// 离屏宿主视图（只为让 layer 处于窗口层级，本体移出屏幕）
  private var hostView: UIView?
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
  /// PiP 开关状态机（与 LyricsPipManager 同款）：start/stop 都是异步指令，
  /// 状态只由 delegate 终态回调推进，在途时记录 pendingIntent 收敛执行。
  private enum PipState { case idle, starting, started, stopping }
  private var pipState: PipState = .idle
  private var pendingIntent: Bool?
  private var awaitingStartCallback = false
  /// 2:1 横向窗口（pt）
  private static let windowSize = CGSize(width: 300, height: 150)

  // 主题配色：由 Dart 经 setThemeColors 推送（应用莫奈/动态取色的
  // ColorScheme token，浅色主题为近白面板、深色主题为深色容器，深浅
  // 匹配由 Dart 侧完成）。未推送前用 MD3E 深色 token 兜底。
  private var panelColor = argb(0xFF1D1B20)
  private var idleCircleColor = argb(0xFF26242B)
  private var onSurfaceColor = argb(0xFFE6E0E9)
  private var onSurfaceVariantColor = argb(0xFFCAC4D0)
  private var errorColor = argb(0xFFFFB4AB)
  private var onErrorColor = argb(0xFF601410)
  private var tertiaryColor = argb(0xFFEFB8C8)
  private var onTertiaryColor = argb(0xFF492532)
  private var resultBgColor = argb(0xFFEADDFF)
  private var onResultColor = argb(0xFF21005D)

  private static func argb(_ value: Int) -> UIColor {
    UIColor(
      red: CGFloat((value >> 16) & 0xFF) / 255.0,
      green: CGFloat((value >> 8) & 0xFF) / 255.0,
      blue: CGFloat(value & 0xFF) / 255.0,
      alpha: 1.0)
  }

  private override init() {}

  /// 注册 MethodChannel（幂等）。attach 与各方法均保证在主线程执行。
  func attach(messenger: FlutterBinaryMessenger) {
    guard channel == nil else { return }
    let ch = FlutterMethodChannel(name: "com.md3music/recognition_pip", binaryMessenger: messenger)
    ch.setMethodCallHandler { [weak self] call, result in
      self?.handle(call: call, result: result)
    }
    channel = ch
    NSLog("[MD3Music] recognition_pip channel registered")
  }

  private func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
    DispatchQueue.main.async { [weak self] in
      guard let self = self else {
        result(FlutterError(code: "gone", message: "SongRecognitionPipManager deallocated", details: nil))
        return
      }
      switch call.method {
      case "start":
        self.start(result: result)
      case "stop":
        self.requestStop()
        result(nil)
      case "update":
        if let args = call.arguments as? [String: Any] {
          self.update(args)
        }
        result(nil)
      case "setThemeColors":
        if let args = call.arguments as? [String: Any] {
          self.applyThemeColors(args)
        }
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  // MARK: update（Dart 识别循环推送窗口状态）

  private func update(_ args: [String: Any]) {
    state = args["state"] as? String ?? "idle"
    let text = args["text"] as? String ?? ""
    hintText = text.isEmpty ? Self.defaultHint(for: state) : text
    songName = args["songName"] as? String ?? ""
    artist = args["artist"] as? String ?? ""
  }

  // MARK: 主题配色（Dart 推送应用 ColorScheme token）

  /// 应用 Dart 推送的主题色（ARGB int）。窗口下一帧（≤50ms）即用新配色，
  /// 深浅色匹配与莫奈取色都在 Dart 侧由 ColorScheme 完成，这里只做赋值。
  private func applyThemeColors(_ args: [String: Any]) {
    func color(_ key: String, current: UIColor) -> UIColor {
      guard let v = args[key] as? Int else { return current }
      return Self.argb(v)
    }
    panelColor = color("panel", current: panelColor)
    idleCircleColor = color("idleCircle", current: idleCircleColor)
    onSurfaceColor = color("onSurface", current: onSurfaceColor)
    onSurfaceVariantColor = color("onSurfaceVariant", current: onSurfaceVariantColor)
    errorColor = color("error", current: errorColor)
    onErrorColor = color("onError", current: onErrorColor)
    tertiaryColor = color("tertiary", current: tertiaryColor)
    onTertiaryColor = color("onTertiary", current: onTertiaryColor)
    resultBgColor = color("resultBg", current: resultBgColor)
    onResultColor = color("onResult", current: onResultColor)
  }

  private static func defaultHint(for state: String) -> String {
    switch state {
    case "listening": return "正在聆听..."
    case "recognizing": return "正在识别..."
    case "stopped": return "未识别到歌曲"
    default: return "点击开始听歌识曲"
    }
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
    // PiP 需要活跃的音频会话（识别循环期间 Dart 侧配置为 playAndRecord）
    try? AVAudioSession.sharedInstance().setActive(true)
    // 先画一帧：layer 无帧时系统不会开窗
    renderFrame()
    requestStart()
    NSLog("[MD3Music] recognition pip start requested")
    // 已受理；真实激活态由 didStart/didStop -> 'state' 回调回报
    result(true)
  }

  // MARK: 开关状态机（与 LyricsPipManager 同款：请求只记录意图，终态回调收敛）

  private func requestStart() {
    switch pipState {
    case .started:
      notifyState(active: true)
    case .starting, .stopping:
      pendingIntent = true
    case .idle:
      pipState = .starting
      pendingIntent = true
      scheduleStartAttempt(attempt: 0)
    }
  }

  private func requestStop() {
    switch pipState {
    case .idle:
      notifyState(active: false)
    case .starting:
      startRetry?.cancel()
      pendingIntent = false
      if !awaitingStartCallback {
        pipState = .idle
        pendingIntent = nil
        notifyState(active: false)
      }
    case .started:
      pipState = .stopping
      pendingIntent = false
      pipController?.stopPictureInPicture()
    case .stopping:
      pendingIntent = false
    }
  }

  private func handleDidStart() {
    pipState = .started
    awaitingStartCallback = false
    if pendingIntent == false {
      pendingIntent = nil
      pipState = .stopping
      pipController?.stopPictureInPicture()
      return
    }
    pendingIntent = nil
    startFrameLoop()
    notifyState(active: true)
  }

  private func handleDidStop() {
    pipState = .idle
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

  private func handleStartFailed() {
    pipState = .idle
    awaitingStartCallback = false
    pendingIntent = nil
    stopFrameLoop()
    notifyState(active: false)
  }

  /// 构建 SampleBuffer 式 PiP 基础设施（幂等）。
  @available(iOS 15.0, *)
  private func buildInfrastructureIfNeeded() {
    guard pipController == nil else { return }
    guard let rootViewController = keyRootViewController() else {
      NSLog("[MD3Music] recognition pip no root view controller!")
      return
    }
    // 1. 离屏宿主：layer 必须在窗口层级里 PiP 才会从它取帧
    let host = UIView(frame: CGRect(
      x: -Self.windowSize.width - 16, y: -8,
      width: Self.windowSize.width, height: Self.windowSize.height))
    host.backgroundColor = .clear
    host.isUserInteractionEnabled = false
    rootViewController.view.addSubview(host)
    sampleLayer.videoGravity = .resizeAspect
    sampleLayer.frame = host.bounds
    host.layer.addSublayer(sampleLayer)
    hostView = host

    // 2. controller + 双协议代理（生命周期 + sample buffer 播放控制）
    let lifecycle = SongRecognitionPipLifecycleDelegate()
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
      NSLog("[MD3Music] recognition pip failed to start: \(message)")
      self?.handleStartFailed()
    }
    // 还原按钮不额外回调：restore 回前台即退出悬浮模式，由 Dart 侧
    // 监听 state(active:false) 统一收尾（停止循环、结果经回前台展示）
    delegateHolder = lifecycle
    let contentSource = AVPictureInPictureController.ContentSource(
      sampleBufferDisplayLayer: sampleLayer,
      playbackDelegate: lifecycle)
    let controller = AVPictureInPictureController(contentSource: contentSource)
    controller.delegate = lifecycle
    controller.requiresLinearPlayback = true
    // 私有样式：去掉播放/暂停/跳过等传输控件，只留系统关闭(X)/还原按钮
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
      guard let self = self, self.pipState == .starting, self.pendingIntent == true else { return }
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
          "[MD3Music] recognition pip start gave up: possible=\(controller.isPictureInPicturePossible), infraReady=\(infraReady)")
        self.pipState = .idle
        self.pendingIntent = nil
        self.notifyState(active: false)
      }
    }
    startRetry = work
    let delay: DispatchTimeInterval = attempt == 0 ? .milliseconds(20) : .milliseconds(120)
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
  }

  private func notifyState(active: Bool) {
    channel?.invokeMethod("state", arguments: ["active": active])
  }

  // MARK: SampleBuffer 帧管线（frameTimer 每帧调用）

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

  /// 渲染一帧并入队：@2x 位图上画识别窗 → blit 进 CVPixelBuffer → 包成
  /// CMSampleBuffer enqueue。
  private func renderFrame() {
    guard let sample = makeSample() else { return }
    // failed 态的 renderer 会静默吞帧（表现为画面冻结），先 flush 再入队
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
    format.scale = 2 // @2x 位图（600x300）
    format.opaque = true
    let renderer = UIGraphicsImageRenderer(size: Self.windowSize, format: format)
    let image = renderer.image { ctx in
      // 渲染器上下文已是 UIKit 左上原点坐标系，与 drawWindow 的坐标约定一致
      self.drawWindow(in: ctx.cgContext, size: Self.windowSize)
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
    // PTS 取 hostTime 当前时刻 + DisplayImmediately：每帧到达即显示
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

  // MARK: 识别窗绘制（makeSample 的位图上下文调用，UIKit 坐标系）

  private func drawWindow(in ctx: CGContext, size: CGSize) {
    let w = size.width
    let h = size.height
    // 面板底色：SampleBuffer 是不透明视频帧，用实色深色面板
    ctx.setFillColor(Self.panelColor.cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))

    // —— 左侧圆形麦克风标 ——
    let diameter = h * 0.61
    let cx = h * 0.44
    let cy = h / 2
    let listening = state == "listening"

    // 聆听中脉冲缩放：1.0→1.15，1.2s 往返（对齐识曲页 1200ms easeInOut）
    var scale: CGFloat = 1
    if listening {
      let period = 1.2
      let t = ProcessInfo.processInfo.systemUptime
        .truncatingRemainder(dividingBy: period * 2) / period
      let p = t > 1 ? 2 - t : t
      scale = 1 + 0.15 * CGFloat(p * p * (3 - 2 * p))
    }
    let radius = diameter / 2 * scale

    var circleColor = Self.idleCircleColor
    var iconColor = Self.onSurfaceColor
    switch state {
    case "listening":
      circleColor = Self.errorColor
      iconColor = Self.onErrorColor
    case "recognizing":
      circleColor = Self.tertiaryColor
      iconColor = Self.onTertiaryColor
    case "result":
      circleColor = Self.resultBgColor
      iconColor = Self.onResultColor
    default:
      break
    }

    // 红色边缘发光：聆听中外扩三层描边模拟柔光
    if listening {
      let glow: [(extra: CGFloat, alpha: CGFloat)] = [(3, 0.5), (8, 0.28), (15, 0.13)]
      for g in glow {
        let r = radius + g.extra
        ctx.setStrokeColor(Self.errorColor.withAlphaComponent(g.alpha).cgColor)
        ctx.setLineWidth(g.extra)
        ctx.strokeEllipse(in: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
      }
    }

    ctx.setFillColor(circleColor.cgColor)
    ctx.fillEllipse(in: CGRect(x: cx - radius, y: cy - radius, width: radius * 2, height: radius * 2))

    // 图标：结果态对勾，其余画麦克风
    let iconSize = diameter * 0.52
    if state == "result" {
      drawCheck(cx: cx, cy: cy, size: iconSize, color: iconColor)
    } else {
      drawMic(cx: cx, cy: cy, size: iconSize, color: iconColor)
    }

    // —— 右侧文案区 ——
    let textX = cx + diameter / 2 + h * 0.12
    let textMaxWidth = w - textX - h * 0.10
    if state == "result" {
      drawResultText(x: textX, maxWidth: textMaxWidth, height: h)
    } else {
      drawHintText(x: textX, maxWidth: textMaxWidth, height: h)
    }
  }

  /// 麦克风图标：U 型拾音架 + 拾音头胶囊 + 笔杆 + 底座（单位方坐标）。
  /// 先画拾音架再画胶囊，重叠处由胶囊覆盖，观感干净。
  private func drawMic(cx: CGFloat, cy: CGFloat, size: CGFloat, color: UIColor) {
    let ox = cx - size / 2
    let oy = cy - size / 2
    color.setStroke()

    // U 型拾音架（开口朝上）
    let arc = UIBezierPath()
    arc.addArc(
      withCenter: CGPoint(x: ox + size / 2, y: oy + size * 0.52),
      radius: size * 0.21,
      startAngle: 0,
      endAngle: .pi,
      clockwise: true)
    arc.lineWidth = size * 0.055
    arc.lineCapStyle = .round
    arc.stroke()

    // 拾音头胶囊
    color.setFill()
    let capW = size * 0.34
    let capRect = CGRect(
      x: ox + (size - capW) / 2, y: oy + size * 0.14,
      width: capW, height: size * 0.40)
    UIBezierPath(roundedRect: capRect, cornerRadius: capW / 2).fill()

    // 笔杆
    let stem = UIBezierPath()
    stem.move(to: CGPoint(x: ox + size / 2, y: oy + size * 0.73))
    stem.addLine(to: CGPoint(x: ox + size / 2, y: oy + size * 0.81))
    stem.lineWidth = size * 0.055
    stem.lineCapStyle = .round
    stem.stroke()

    // 底座
    let base = UIBezierPath()
    base.move(to: CGPoint(x: ox + size * 0.34, y: oy + size * 0.86))
    base.addLine(to: CGPoint(x: ox + size * 0.66, y: oy + size * 0.86))
    base.lineWidth = size * 0.055
    base.lineCapStyle = .round
    base.stroke()
  }

  /// 对勾图标（识别成功态）
  private func drawCheck(cx: CGFloat, cy: CGFloat, size: CGFloat, color: UIColor) {
    let path = UIBezierPath()
    path.move(to: CGPoint(x: cx - size * 0.26, y: cy + size * 0.02))
    path.addLine(to: CGPoint(x: cx - size * 0.06, y: cy + size * 0.22))
    path.addLine(to: CGPoint(x: cx + size * 0.28, y: cy - size * 0.20))
    path.lineWidth = size * 0.10
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    color.setStroke()
    path.stroke()
  }

  /// 单行状态文案：超宽逐步缩字号，仍超则尾部省略
  private func drawHintText(x: CGFloat, maxWidth: CGFloat, height: CGFloat) {
    let muted = state == "idle" || state == "stopped"
    var fontSize: CGFloat = 15
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byTruncatingTail
    var attrs: [NSAttributedString.Key: Any] = [
      .font: UIFont.systemFont(ofSize: fontSize, weight: .medium),
      .foregroundColor: muted ? Self.onSurfaceVariantColor : Self.onSurfaceColor,
      .paragraphStyle: paragraph,
    ]
    let text = hintText as NSString
    var textSize = text.size(withAttributes: attrs)
    while textSize.width > maxWidth && fontSize > 11 {
      fontSize -= 0.5
      attrs[.font] = UIFont.systemFont(ofSize: fontSize, weight: .medium)
      textSize = text.size(withAttributes: attrs)
    }
    text.draw(
      with: CGRect(x: x, y: (height - textSize.height) / 2, width: maxWidth, height: textSize.height),
      options: .usesLineFragmentOrigin, attributes: attrs, context: nil)
  }

  /// 结果态：歌名（粗体）+ 歌手（灰），整体垂直居中，尾部省略
  private func drawResultText(x: CGFloat, maxWidth: CGFloat, height: CGFloat) {
    let nameFont = UIFont.systemFont(ofSize: 15.5, weight: .bold)
    let artistFont = UIFont.systemFont(ofSize: 12.5, weight: .regular)
    let name = (songName.isEmpty ? "未知歌曲" : songName) as NSString
    let showArtist = !artist.isEmpty
    let artistText = artist as NSString

    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byTruncatingTail
    let nameAttrs: [NSAttributedString.Key: Any] = [
      .font: nameFont,
      .foregroundColor: Self.onSurfaceColor,
      .paragraphStyle: paragraph,
    ]
    let artistAttrs: [NSAttributedString.Key: Any] = [
      .font: artistFont,
      .foregroundColor: Self.onSurfaceVariantColor,
      .paragraphStyle: paragraph,
    ]
    let nameSize = name.size(withAttributes: nameAttrs)
    let artistSize = showArtist ? artistText.size(withAttributes: artistAttrs) : .zero
    let gap: CGFloat = showArtist ? 5 : 0
    let totalHeight = nameSize.height + gap + artistSize.height
    var y = (height - totalHeight) / 2

    name.draw(
      with: CGRect(x: x, y: y, width: maxWidth, height: nameSize.height),
      options: .usesLineFragmentOrigin, attributes: nameAttrs, context: nil)
    y += nameSize.height + gap
    if showArtist {
      artistText.draw(
        with: CGRect(x: x, y: y, width: maxWidth, height: artistSize.height),
        options: .usesLineFragmentOrigin, attributes: artistAttrs, context: nil)
    }
  }
}

/// PiP 双协议代理：AVPictureInPictureControllerDelegate（生命周期）+
/// AVPictureInPictureSampleBufferPlaybackDelegate（sample buffer 播放控制）。
/// 播放控制按"只读仪表"语义实现——窗口不是播放器，不响应播放/seek，仅维持
/// "永远在播"的表象让系统不叠加暂停态。
private final class SongRecognitionPipLifecycleDelegate: NSObject,
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
    // 还原按钮：返回 true 让系统把 App 拉回前台即可。PiP 随还原操作关闭，
    // Dart 侧监听 state(active:false) 结束悬浮模式，不重开小窗。
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
    // 识别用的麦克风会话与本 app 的音频会话同属一个进程，绝不能禁止后台音频
    false
  }
}
