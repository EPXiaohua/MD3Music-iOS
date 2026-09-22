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

  static func load() -> WidgetState {
    var s = WidgetState()
    guard let defaults = UserDefaults(suiteName: WidgetSyncBridge.appGroupId),
      let data = defaults.data(forKey: "widget_state"),
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
    if let container = FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: WidgetSyncBridge.appGroupId)
    {
      s.coverImage = UIImage(
        contentsOfFile: container.appendingPathComponent("widget_cover.png")
          .path)
    }
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

  /// 小号：封面 + 标题/歌手 + 进度
  private func smallLayout(_ s: WidgetState) -> some View {
    HStack(spacing: 10) {
      coverView(s, size: 52)
      VStack(alignment: .leading, spacing: 3) {
        textBlock(s)
        progressView(s)
      }
    }
    .padding(.horizontal, 4)
  }

  /// 中号：封面 + 标题/歌手 + 进度 + 播放/下一首按钮
  private func mediumLayout(_ s: WidgetState) -> some View {
    HStack(spacing: 12) {
      coverView(s, size: 64)
      VStack(alignment: .leading, spacing: 4) {
        textBlock(s)
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
    }
    .padding(.horizontal, 4)
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

  private func textBlock(_ s: WidgetState) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(s.title.isEmpty ? "MD3Music" : s.title)
        .font(.system(size: 14, weight: .semibold))
        .foregroundColor(s.onSurface)
        .lineLimit(1)
      Text(s.artist.isEmpty ? "未在播放" : s.artist)
        .font(.system(size: 12))
        .foregroundColor(s.onSurfaceVariant)
        .lineLimit(1)
    }
  }

  private func progressView(_ s: WidgetState) -> some View {
    TimelineView(.periodic(from: .now, by: 1)) { _ in
      GeometryReader { geo in
        ZStack(alignment: .leading) {
          Capsule().fill(s.outlineVariant)
          Capsule()
            .fill(s.primary)
            .frame(width: geo.size.width * progressFraction(s))
        }
      }
      .frame(height: 4)
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

/// iOS 17 的 widget 必须声明 containerBackground，否则内容不可见；
/// iOS 15/16 用普通 background。
private extension View {
  @ViewBuilder
  func widgetBackground(_ color: Color) -> some View {
    if #available(iOSApplicationExtension 17.0, *) {
      containerBackground(for: .widget) { color }
    } else {
      background(color)
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
    UserDefaults(suiteName: appGroupId)?.set(action, forKey: "widget_command")
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
