//
//  MD3Widget.swift
//  MD3Widget
//
//  音乐播放器桌面小组件（WidgetKit）。两个尺寸对齐 Android 组件：
//  - 小号（systemSmall）= Android 2x2 封面播放器：封面全幅铺底 +
//    封面主色（简化 vibrant）渐变遮罩，中部歌名/歌手，底部
//    上一首/播放暂停/下一首三键；
//  - 中号（systemMedium）= 歌曲展示台：左侧大封面，右侧歌名/歌手 +
//    进度条 + 时间 + 三键，颜色由 app 推送的 ColorScheme 色板
//    （App Group "widget_state" 的 colors 字段）驱动。
//
//  数据来源：主 app 的 WidgetSync 写入 App Group（group.com.md3music.md3music）
//  的 widget_state JSON 与 widget_cover.png；app 每次播放状态变化时调用
//  WidgetCenter.reloadAllTimelines() 刷新。
//
//  进度条：播放中用 TimelineView(.periodic) 每秒按墙钟推进（position +
//  (now - updatedAt)），无需依赖系统刷新预算；暂停时静止。
//
//  交互：iOS 17+ 按钮走 AppIntent——把命令写入 App Group 并打开 app，由
//  主 app 回前台后转发给 Dart 执行；iOS 16 按钮用 Link 经
//  `md3music://widget/<action>` URL scheme 打开 app 携带命令（iOS 15 点整
//  个 widget 走 widgetURL 兜底）；主 app 由 SceneDelegate 接收 URL 后同样
//  经 WidgetSync 转发给 Dart。
//

import WidgetKit
import SwiftUI
import AppIntents

// MARK: - 数据模型

struct WidgetState {
  var title = ""
  var artist = ""
  var isPlaying = false
  var positionMs = 0
  var durationMs = 0
  /// 状态写入时刻（墙钟），用于播放中推进进度
  var updatedAt = Date()
  var colors: [String: Int] = [:]
  var coverImage: UIImage?

  /// 读取 App Group 里的播放状态；不可用时返回空 state（视图显示默认占位文案）。
  static func load() -> WidgetState {
    var s = WidgetState()
    let groupId = WidgetSyncBridge.resolvedAppGroupId
    guard
      let defaults = UserDefaults(suiteName: groupId),
      let container = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: groupId)
    else { return s }
    s.coverImage = UIImage(
      contentsOfFile: container.appendingPathComponent("widget_cover.png").path)
    guard let data = defaults.data(forKey: "widget_state"),
      let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    else { return s }
    s.title = dict["title"] as? String ?? ""
    s.artist = dict["artist"] as? String ?? ""
    s.isPlaying = dict["isPlaying"] as? Bool ?? false
    s.positionMs = dict["position"] as? Int ?? 0
    s.durationMs = dict["duration"] as? Int ?? 0
    s.updatedAt = Date(
      timeIntervalSince1970: dict["updatedAt"] as? Double ?? 0)
    s.colors = dict["colors"] as? [String: Int] ?? [:]
    return s
  }

  /// 当前实际进度（ms）：播放中按墙钟推进，暂停时静止
  var livePositionMs: Int {
    guard isPlaying else { return positionMs }
    let elapsed = Int(Date().timeIntervalSince(updatedAt) * 1000)
    return min(positionMs + max(0, elapsed), max(durationMs, 1))
  }

  /// 封面主色（简化 vibrant）：缩到 24x24 统计饱和像素的色相分布，
  /// 取最高频色相桶的平均色相/饱和度，亮度固定 0.62——对应 Android
  /// 封面播放器用 Palette 取色做遮罩/按钮底色的行为。近灰封面返回 nil。
  static func coverAccent(from image: UIImage?) -> UIColor? {
    guard let cg = image?.cgImage else { return nil }
    let w = 24, h = 24
    var pixels = [UInt8](repeating: 0, count: w * h * 4)
    let drawn: Bool = pixels.withUnsafeMutableBytes { raw -> Bool in
      guard
        let ctx = CGContext(
          data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
          bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      else { return false }
      ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
      return true
    }
    guard drawn else { return nil }
    var bucketCount = [Int](repeating: 0, count: 24)
    var bucketHue = [Double](repeating: 0, count: 24)
    var bucketSat = [Double](repeating: 0, count: 24)
    var colored = 0
    for i in stride(from: 0, to: pixels.count, by: 4) {
      let a = Double(pixels[i + 3]) / 255
      guard a > 0.5 else { continue }
      let r = Double(pixels[i]) / 255
      let g = Double(pixels[i + 1]) / 255
      let b = Double(pixels[i + 2]) / 255
      let mx = max(r, g, b)
      let mn = min(r, g, b)
      let v = mx
      let sat = mx == 0 ? 0 : (mx - mn) / mx
      // 跳过近黑/近白/低饱和像素，只统计"有颜色"的部分
      guard v > 0.22, v < 0.98, sat > 0.28 else { continue }
      var hue: Double
      if mx == mn {
        hue = 0
      } else if mx == r {
        hue = (g - b) / (mx - mn)
      } else if mx == g {
        hue = 2 + (b - r) / (mx - mn)
      } else {
        hue = 4 + (r - g) / (mx - mn)
      }
      if hue < 0 { hue += 6 }
      let bucket = min(Int(hue / 6 * 24), 23)
      bucketCount[bucket] += 1
      bucketHue[bucket] += hue / 6
      bucketSat[bucket] += sat
      colored += 1
    }
    guard colored > 8 else { return nil }
    var best = 0
    for i in 1..<24 where bucketCount[i] > bucketCount[best] { best = i }
    guard bucketCount[best] > 0 else { return nil }
    let hue = bucketHue[best] / Double(bucketCount[best])
    let sat = min(max(bucketSat[best] / Double(bucketCount[best]), 0.45), 0.85)
    return UIColor(hue: CGFloat(hue), saturation: CGFloat(sat), brightness: 0.62, alpha: 1)
  }
}

/// App Group 访问桥（extension 与 app 两侧共用常量）
enum WidgetSyncBridge {
  static let appGroupId = "group.com.md3music.md3music"

  // 免费签名工具（isideload 等）签发时 App Group id 会变成
  // `group.<bundle>.<TEAM_ID>` 格式。与 app 侧 WidgetSync 相同的策略：
  // 用私有 API SecTaskCopyValueForEntitlement 读自身签名的
  // application-groups，找到第一个容器可访问的，失败回退声明 id。
  private static var _resolved: String?

  static var resolvedAppGroupId: String {
    if let r = _resolved { return r }
    let resolved = findUsableAppGroup() ?? appGroupId
    _resolved = resolved
    return resolved
  }

  private static func findUsableAppGroup() -> String? {
    var candidates = signedAppGroups() ?? []
    if !candidates.contains(appGroupId) { candidates.append(appGroupId) }
    for g in candidates
    where FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: g) != nil
    {
      return g
    }
    return nil
  }

  private static func signedAppGroups() -> [String]? {
    guard
      let security = dlopen(
        "/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY),
      let createSym = dlsym(security, "SecTaskCreateFromSelf"),
      let copySym = dlsym(security, "SecTaskCopyValueForEntitlement")
    else { return nil }
    typealias CreateFn = @convention(c) (CFAllocator?) -> OpaquePointer?
    typealias CopyFn =
      @convention(c) (OpaquePointer?, CFString, UnsafeMutableRawPointer?) ->
      CFTypeRef?
    guard
      let task = unsafeBitCast(createSym, to: CreateFn.self)(nil)
    else { return nil }
    guard
      let value = unsafeBitCast(copySym, to: CopyFn.self)(
        task, "com.apple.security.application-groups" as CFString, nil)
    else { return nil }
    let list = (value as? [Any])?.compactMap { $0 as? String }
    return (list?.isEmpty ?? true) ? nil : list
  }
}

// MARK: - 颜色

private extension WidgetState {
  /// ARGB Int → SwiftUI Color；缺省回落到系统语义色（自动深浅色）
  func color(_ key: String, fallback: Color) -> Color {
    guard let argb = colors[key] else { return fallback }
    return Color(
      UIColor(
        red: CGFloat((argb >> 16) & 0xFF) / 255,
        green: CGFloat((argb >> 8) & 0xFF) / 255,
        blue: CGFloat(argb & 0xFF) / 255,
        alpha: CGFloat((argb >> 24) & 0xFF) / 255))
  }

  var panelBg: Color { color("panelBg", fallback: Color(UIColor.systemBackground)) }
  var primary: Color { color("primary", fallback: Color(UIColor.systemBlue)) }
  var onPrimary: Color { color("onPrimary", fallback: .white) }
  var onSurface: Color { color("onSurface", fallback: Color(UIColor.label)) }
  var onSurfaceVariant: Color {
    color("onSurfaceVariant", fallback: Color(UIColor.secondaryLabel))
  }
  var surfaceHigh: Color {
    color("surfaceHigh", fallback: Color(UIColor.secondarySystemBackground))
  }
  var outlineVariant: Color {
    color("outlineVariant", fallback: Color(UIColor.systemFill))
  }
}

// MARK: - Timeline

struct MusicEntry: TimelineEntry {
  let date: Date
  let state: WidgetState
}

struct MusicProvider: TimelineProvider {
  func placeholder(in context: Context) -> MusicEntry {
    MusicEntry(date: Date(), state: WidgetState())
  }

  func getSnapshot(in context: Context, completion: @escaping (MusicEntry) -> Void) {
    completion(MusicEntry(date: Date(), state: WidgetState.load()))
  }

  func getTimeline(in context: Context, completion: @escaping (Timeline<MusicEntry>) -> Void) {
    let entry = MusicEntry(date: Date(), state: WidgetState.load())
    // 单条 entry：进度由视图内 TimelineView 实时推进，状态更新由 app 主动
    // reloadAllTimelines 驱动；atEnd 让系统在预算内重读最新状态
    completion(Timeline(entries: [entry], policy: .atEnd))
  }
}

// MARK: - 视图

struct MD3MusicWidgetView: View {
  @Environment(\.widgetFamily) var family
  var entry: MusicEntry

  var body: some View {
    let s = entry.state
    Group {
      if family == .systemMedium {
        showcaseLayout(s)
      } else {
        coverPlayerLayout(s)
      }
    }
    .widgetBackground(backgroundView(s))
    // 兜底：iOS 15/16 点击非按钮区域打开 app（按钮区域 Link 优先）；
    // iOS 17+ 按钮走 AppIntent，其余区域同样能打开 app
    .widgetURL(URL(string: "md3music://widget/open"))
  }

  /// 组件背景层：小号 = 封面铺底 + 封面主色渐变遮罩（文字/按钮画在
  /// 内容层，遮罩负责对比度）；中号 = 展示台纯色底（推送的 panelBg）。
  @ViewBuilder
  private func backgroundView(_ s: WidgetState) -> some View {
    if family == .systemMedium {
      s.panelBg
    } else {
      ZStack {
        if let image = s.coverImage {
          Image(uiImage: image)
            .resizable()
            .scaledToFill()
        } else {
          Color(UIColor(s.primary))
        }
        scrimGradient(s)
      }
      .clipped()
    }
  }

  /// 莫奈遮罩：封面主色自上而下加深（顶 30% 透出封面 → 底 78% 保证
  /// 按钮区可读）；无封面时用主题 primary 淡化铺底。
  private func scrimGradient(_ s: WidgetState) -> some View {
    let accent = UIColor.coverAccent(from: s.coverImage) ?? UIColor(s.primary)
    return LinearGradient(
      stops: [
        .init(color: Color(accent).opacity(0.30), location: 0),
        .init(color: Color(accent).opacity(0.55), location: 0.55),
        .init(color: Color(accent).opacity(0.78), location: 1),
      ],
      startPoint: .top, endPoint: .bottom)
  }

  /// 小号（Android 2x2 封面播放器）：中部歌名/歌手，底部三键。
  private func coverPlayerLayout(_ s: WidgetState) -> some View {
    VStack(spacing: 0) {
      Spacer(minLength: 0)
      VStack(spacing: 3) {
        Text(s.title.isEmpty ? "MD3Music" : s.title)
          .font(.system(size: 12, weight: .semibold))
          .foregroundColor(.white)
          .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
          .lineLimit(1)
          .truncationMode(.tail)
        Text(s.artist.isEmpty ? "未在播放" : s.artist)
          .font(.system(size: 10))
          .foregroundColor(.white.opacity(0.85))
          .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
          .lineLimit(1)
          .truncationMode(.tail)
      }
      .padding(.horizontal, 12)
      Spacer(minLength: 0)
      transportRow(s, compact: true)
        .padding(.bottom, 14)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  /// 中号 = 歌曲展示台：左侧大封面，右侧歌名/歌手 + 进度 + 时间 + 三键。
  private func showcaseLayout(_ s: WidgetState) -> some View {
    HStack(alignment: .center, spacing: 14) {
      bigCover(s, size: 104)
      VStack(alignment: .leading, spacing: 0) {
        Text(s.title.isEmpty ? "MD3Music" : s.title)
          .font(.system(size: 15, weight: .semibold))
          .foregroundColor(s.onSurface)
          .lineLimit(2)
          .truncationMode(.tail)
        Text(s.artist.isEmpty ? "未在播放" : s.artist)
          .font(.system(size: 12))
          .foregroundColor(s.onSurfaceVariant)
          .lineLimit(1)
          .truncationMode(.tail)
          .padding(.top, 3)
        Spacer(minLength: 0)
        progressWithTime(s)
        Spacer(minLength: 0)
        transportRow(s, compact: false)
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 14)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  /// 展示台大封面（圆角矩形）
  private func bigCover(_ s: WidgetState, size: CGFloat) -> some View {
    ZStack {
      if let image = s.coverImage {
        Image(uiImage: image)
          .resizable()
          .scaledToFill()
      } else {
        Rectangle().fill(s.outlineVariant)
          .overlay(
            Image(systemName: "music.note")
              .font(.system(size: size * 0.34))
              .foregroundColor(s.onSurfaceVariant))
      }
    }
    .frame(width: size, height: size)
    .clipShape(RoundedRectangle(cornerRadius: size * 0.18, style: .continuous))
  }

  /// 进度条 + 当前/总时长（展示台右列中部）
  private func progressWithTime(_ s: WidgetState) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      TimelineView(.periodic(from: .now, by: 1)) { _ in
        GeometryReader { geo in
          let w = max(geo.size.width, 0)
          ZStack(alignment: .leading) {
            Capsule().fill(s.outlineVariant)
            Capsule()
              .fill(s.primary)
              .frame(width: min(w * progressFraction(s), w))
          }
        }
        .frame(height: 4)
        .animation(.linear(duration: 1), value: progressFraction(s))
      }
      .frame(height: 4)
      HStack {
        Text(formatMs(s.livePositionMs))
        Spacer()
        Text(formatMs(s.durationMs))
      }
      .font(.system(size: 10).monospacedDigit())
      .foregroundColor(s.onSurfaceVariant)
    }
  }

  /// 三键行：上一首 / 播放暂停 / 下一首。小号用裸图标 + 白色半透明
  /// 圆底播放键（封面播放器样式）；中号播放键用主题 primary 圆底。
  private func transportRow(_ s: WidgetState, compact: Bool) -> some View {
    let iconSize: CGFloat = compact ? 14 : 17
    let playSize: CGFloat = compact ? 40 : 42
    let spacing: CGFloat = compact ? 26 : 18
    return HStack(spacing: spacing) {
      transportButton(action: "previous") {
        Image(systemName: "backward.end.fill")
          .font(.system(size: iconSize, weight: .semibold))
          .foregroundColor(compact ? .white : s.onSurface)
          .frame(width: playSize * 0.8, height: playSize * 0.8)
          .shadow(color: .black.opacity(compact ? 0.35 : 0), radius: 2)
      }
      transportButton(action: "play_pause") {
        Image(systemName: s.isPlaying ? "pause.fill" : "play.fill")
          .font(.system(size: playSize * 0.42, weight: .semibold))
          .foregroundColor(compact ? Color(UIColor(white: 0.13, alpha: 1)) : s.onPrimary)
          .frame(width: playSize, height: playSize)
          .background(
            Circle().fill(compact ? Color.white.opacity(0.82) : s.primary))
      }
      transportButton(action: "next") {
        Image(systemName: "forward.end.fill")
          .font(.system(size: iconSize, weight: .semibold))
          .foregroundColor(compact ? .white : s.onSurface)
          .frame(width: playSize * 0.8, height: playSize * 0.8)
          .shadow(color: .black.opacity(compact ? 0.35 : 0), radius: 2)
      }
    }
  }

  /// 单个传输按钮：iOS 17+ AppIntent 直控，iOS 16 Link 带命令打开 app
  /// （iOS 15 整组件点按走 widgetURL 兜底）。
  @ViewBuilder
  private func transportButton(
    action: String, @ViewBuilder content: () -> some View
  ) -> some View {
    let url = URL(string: "md3music://widget/\(action)")!
    if #available(iOSApplicationExtension 17.0, *) {
      switch action {
      case "previous":
        Button(intent: PreviousIntent()) { content() }.buttonStyle(.plain)
      case "next":
        Button(intent: NextIntent()) { content() }.buttonStyle(.plain)
      default:
        Button(intent: PlayPauseIntent()) { content() }.buttonStyle(.plain)
      }
    } else {
      Link(destination: url) { content() }
    }
  }

  private func progressFraction(_ s: WidgetState) -> CGFloat {
    guard s.durationMs > 0 else { return 0 }
    return CGFloat(min(max(s.livePositionMs, 0), s.durationMs)) / CGFloat(s.durationMs)
  }

  private func formatMs(_ ms: Int) -> String {
    let total = max(ms, 0) / 1000
    return String(format: "%d:%02d", total / 60, total % 60)
  }
}

/// iOS 17 的 widget 必须声明 containerBackground（自动铺满，无白边）；
/// iOS 15/16 没有 containerBackground，内容区外还有系统 content margin
/// （约 16pt），background 只覆盖内容区导致四周露白——用负 padding 把
/// 视图外扩抵消 margin，让背景铺满整个组件。
private extension View {
  @ViewBuilder
  func widgetBackground<V: View>(_ background: V) -> some View {
    if #available(iOSApplicationExtension 17.0, *) {
      containerBackground(for: .widget) { background }
    } else {
      padding(-16).background(background)
    }
  }
}

// MARK: - 交互（iOS 17+）

@available(iOSApplicationExtension 17.0, *)
struct PlayPauseIntent: AppIntent {
  static var title: LocalizedStringResource = "播放 / 暂停"
  static var openAppWhenRun = true

  func perform() async throws -> some IntentResult {
    WidgetSyncBridge.writeCommand("play_pause")
    return .result()
  }
}

@available(iOSApplicationExtension 17.0, *)
struct PreviousIntent: AppIntent {
  static var title: LocalizedStringResource = "上一首"
  static var openAppWhenRun = true

  func perform() async throws -> some IntentResult {
    WidgetSyncBridge.writeCommand("previous")
    return .result()
  }
}

@available(iOSApplicationExtension 17.0, *)
struct NextIntent: AppIntent {
  static var title: LocalizedStringResource = "下一首"
  static var openAppWhenRun = true

  func perform() async throws -> some IntentResult {
    WidgetSyncBridge.writeCommand("next")
    return .result()
  }
}

extension WidgetSyncBridge {
  /// AppIntent 与 app 两侧共用：把命令写入 App Group 待 app 回前台消费
  static func writeCommand(_ action: String) {
    UserDefaults(suiteName: resolvedAppGroupId)?.set(
      action, forKey: "widget_command")
  }
}

// MARK: - Widget 声明

struct MD3MusicWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: "MD3MusicWidget", provider: MusicProvider()) {
      entry in
      MD3MusicWidgetView(entry: entry)
    }
    .configurationDisplayName("音乐播放")
    .description("封面播放器（小）与歌曲展示台（中），支持上一首/播放暂停/下一首")
    .supportedFamilies([.systemSmall, .systemMedium])
  }
}

@main
struct MD3WidgetBundle: WidgetBundle {
  var body: some Widget {
    MD3MusicWidget()
  }
}
