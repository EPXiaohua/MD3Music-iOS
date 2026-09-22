//
//  MD3Widget.swift
//  MD3Widget
//
//  音乐播放器桌面小组件（WidgetKit）。样式对齐 Android MusicWidgetProvider：
//  专辑封面圆角、播放/下一首按钮、进度条，颜色由 app 推送的 ColorScheme
//  色板（App Group "widget_state" 的 colors 字段）驱动，缺省用系统语义色。
//
//  数据来源：主 app 的 WidgetSync 写入 App Group（group.com.md3music.md3music）
//  的 widget_state JSON 与 widget_cover.png；app 每次播放状态变化时调用
//  WidgetCenter.reloadAllTimelines() 刷新。
//
//  进度条：播放中用 TimelineView(.periodic) 每秒按墙钟推进（position +
//  (now - updatedAt)），无需依赖系统刷新预算；暂停时静止。
//
//  交互：iOS 17+ 播放/暂停、下一首按钮走 AppIntent——把命令写入 App Group
//  并打开 app，由主 app 回前台后转发给 Dart 执行；iOS 15/16 点击整个
//  widget 打开 app。
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
        mediumLayout(s)
      } else {
        smallLayout(s)
      }
    }
    .widgetBackground(s.panelBg)
  }

  /// 小号：封面在上、信息在中、进度条在下，整体居中。
  private func smallLayout(_ s: WidgetState) -> some View {
    VStack(spacing: 7) {
      coverView(s, size: 78)
      VStack(spacing: 2) {
        plainText(
          s.title.isEmpty ? "MD3Music" : s.title,
          fontSize: 9, weight: .semibold, color: s.onSurface,
          alignment: .center)
        plainText(
          s.artist.isEmpty ? "未在播放" : s.artist,
          fontSize: 7, weight: .regular, color: s.onSurfaceVariant,
          alignment: .center)
      }
      progressView(s)
    }
    .padding(.horizontal, 10)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  /// 中号（参照设计图）：上排封面+歌曲信息，中间通栏进度条，底部播放/下一首按钮。
  private func mediumLayout(_ s: WidgetState) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 12) {
        coverView(s, size: 56)
        VStack(alignment: .leading, spacing: 3) {
          plainText(
            s.title.isEmpty ? "MD3Music" : s.title,
            fontSize: 14, weight: .semibold, color: s.onSurface,
            alignment: .leading)
          plainText(
            s.artist.isEmpty ? "未在播放" : s.artist,
            fontSize: 12, weight: .regular, color: s.onSurfaceVariant,
            alignment: .leading)
        }
      }
      progressView(s)
      HStack(spacing: 10) {
        // iOS 17+ 按钮绑定 AppIntent 真实控制播放；15/16 纯图标，
        // 点击 widget 整体打开 app
        if #available(iOSApplicationExtension 17.0, *) {
          Button(intent: PlayPauseIntent()) {
            controlCircle(
              systemName: s.isPlaying ? "pause.fill" : "play.fill",
              tint: s.primary, icon: s.onPrimary)
          }
          .buttonStyle(.plain)
          Button(intent: NextIntent()) {
            controlCircle(
              systemName: "forward.fill", tint: s.surfaceHigh,
              icon: s.onSurface)
          }
          .buttonStyle(.plain)
        } else {
          controlCircle(
            systemName: s.isPlaying ? "pause.fill" : "play.fill",
            tint: s.primary, icon: s.onPrimary)
          controlCircle(
            systemName: "forward.fill", tint: s.surfaceHigh,
            icon: s.onSurface)
        }
        Spacer()
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func coverView(_ s: WidgetState, size: CGFloat) -> some View {
    ZStack {
      if let image = s.coverImage {
        Image(uiImage: image)
          .resizable()
          .scaledToFill()
      } else {
        Rectangle().fill(s.outlineVariant)
          .overlay(
            Image(systemName: "music.note")
              .font(.system(size: size * 0.4))
              .foregroundColor(s.onSurfaceVariant))
      }
    }
    .frame(width: size, height: size)
    .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
  }

  /// 单行文本，超宽省略号截断。
  private func plainText(
    _ text: String, fontSize: CGFloat, weight: Font.Weight, color: Color,
    alignment: Alignment
  ) -> some View {
    Text(text)
      .font(.system(size: fontSize, weight: weight))
      .foregroundColor(color)
      .lineLimit(1)
      .truncationMode(.tail)
      .frame(maxWidth: .infinity, alignment: alignment)
      .frame(height: fontSize * 1.25)
  }

  /// 细进度条：左右各内收 11pt（较最初共缩 18pt）避免贴/越组件边缘，
  /// 填充宽度做 clamp 双保险。
  private func progressView(_ s: WidgetState) -> some View {
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
      .padding(.horizontal, 11)
      .animation(.linear(duration: 1), value: progressFraction(s))
    }
  }

  private func progressFraction(_ s: WidgetState) -> CGFloat {
    guard s.durationMs > 0 else { return 0 }
    return CGFloat(min(max(s.livePositionMs, 0), s.durationMs)) / CGFloat(s.durationMs)
  }

  /// 圆形控制按钮外观（不含交互）
  private func controlCircle(systemName: String, tint: Color, icon: Color)
    -> some View
  {
    Image(systemName: systemName)
      .font(.system(size: 13, weight: .semibold))
      .foregroundColor(icon)
      .frame(width: 30, height: 30)
      .background(Circle().fill(tint))
  }
}

/// iOS 17 的 widget 必须声明 containerBackground（自动铺满，无白边）；
/// iOS 15/16 没有 containerBackground，内容区外还有系统 content margin
/// （约 16pt），background 只覆盖内容区导致四周露白——用负 padding 把
/// 视图外扩抵消 margin，让背景铺满整个组件。
private extension View {
  @ViewBuilder
  func widgetBackground(_ color: Color) -> some View {
    if #available(iOSApplicationExtension 17.0, *) {
      containerBackground(for: .widget) { color }
    } else {
      padding(-16).background(color)
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
    .description("显示当前播放的歌曲与进度")
    .supportedFamilies([.systemSmall, .systemMedium])
  }
}

@main
struct MD3WidgetBundle: WidgetBundle {
  var body: some Widget {
    MD3MusicWidget()
  }
}
