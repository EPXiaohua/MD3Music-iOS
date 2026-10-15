//
//  MD3Widget.swift
//  MD3Widget
//
//  音乐播放器桌面小组件（WidgetKit）。两个尺寸对齐 Android 组件：
//  - 小号（systemSmall）= Android 2x2 封面播放器：封面全幅铺底 +
//    封面主色（简化 vibrant）渐变遮罩，中部歌名/歌手，底部
//    上一首/播放暂停/下一首三键；
//  - 中号（systemMedium）= Android 4x2 私人FM电台卡：左侧大封面 +
//    歌名/歌手 + 收藏 + 播放，底排预告封面x3 + 档位按钮；未登录显示
//    登录引导卡。颜色由 app 推送的主题色板（App Group 快照的 colors
//    字段）驱动。
//
//  数据来源：主 app 的 WidgetSync 写入 App Group（group.com.md3music.md3music）
//  的 widget_state / widget_fm_state JSON 与封面文件；app 每次状态变化时
//  调用 WidgetCenter.reloadAllTimelines() 刷新。
//
//  小号进度条：播放中用 TimelineView(.periodic) 每秒按墙钟推进
//  （position + (now - updatedAt)），无需依赖系统刷新预算；暂停时静止。
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

/// ARGB Int → SwiftUI Color（WidgetState 与 WidgetFmState 共用）
private func argbColor(_ argb: Int) -> Color {
  Color(
    UIColor(
      red: CGFloat((argb >> 16) & 0xFF) / 255,
      green: CGFloat((argb >> 8) & 0xFF) / 255,
      blue: CGFloat(argb & 0xFF) / 255,
      alpha: CGFloat((argb >> 24) & 0xFF) / 255))
}

private extension WidgetState {
  /// ARGB Int → SwiftUI Color；缺省回落到系统语义色（自动深浅色）
  func color(_ key: String, fallback: Color) -> Color {
    guard let argb = colors[key] else { return fallback }
    return argbColor(argb)
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

// MARK: - 私人FM卡快照（中号）

/// 中号组件 = 私人FM电台卡（1:1 对齐 Android PersonalFmWidgetProvider）。
/// 数据：Dart FmWidgetSync 推送、宿主 WidgetSync 写入 App Group
/// "widget_fm_state" 的 JSON（全量透传，含 colors 12 色），封面文件
/// fm_cover.png / fm_next_1..3.png 由宿主按 URL 下载。从未收到推送时
/// 一律显示登录引导卡（与 Android lastLoggedIn=false 兜底一致）。
struct WidgetFmState {
  var isLoggedIn = false
  var stationIndex = 0
  var isLoading = false
  var isPlaying = false
  var isFavorite = false
  var title = "点播放，开启你的电台"
  var artist = ""
  var nextHashes = ["", "", ""]
  var colors: [String: Int] = [:]
  var cover: UIImage?
  var nextCovers: [UIImage?] = [nil, nil, nil]

  static func load() -> WidgetFmState {
    var s = WidgetFmState()
    let groupId = WidgetSyncBridge.resolvedAppGroupId
    guard
      let defaults = UserDefaults(suiteName: groupId),
      let container = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: groupId)
    else { return s }
    s.cover = UIImage(
      contentsOfFile: container.appendingPathComponent("fm_cover.png").path)
    for i in 0..<3 {
      s.nextCovers[i] = UIImage(
        contentsOfFile: container.appendingPathComponent("fm_next_\(i + 1).png").path)
    }
    guard let data = defaults.data(forKey: "widget_fm_state"),
      let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    else { return s }
    s.isLoggedIn = dict["isLoggedIn"] as? Bool ?? false
    s.stationIndex = dict["stationIndex"] as? Int ?? 0
    s.isLoading = dict["isLoading"] as? Bool ?? false
    s.isPlaying = dict["isPlaying"] as? Bool ?? false
    s.isFavorite = dict["isFavorite"] as? Bool ?? false
    if let t = dict["title"] as? String, !t.isEmpty { s.title = t }
    s.artist = dict["artist"] as? String ?? ""
    for i in 0..<3 { s.nextHashes[i] = dict["nextHash\(i + 1)"] as? String ?? "" }
    s.colors = dict["colors"] as? [String: Int] ?? [:]
    return s
  }

  func color(_ key: String, fallback: Color) -> Color {
    guard let argb = colors[key] else { return fallback }
    return argbColor(argb)
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
  var surfaceHighest: Color {
    color("surfaceHighest", fallback: Color(UIColor.tertiarySystemFill))
  }
  var primaryContainer: Color {
    color("primaryContainer", fallback: Color(UIColor.systemBlue).opacity(0.18))
  }
  var onPrimaryContainer: Color {
    color("onPrimaryContainer", fallback: Color(UIColor.systemBlue))
  }
}

// MARK: - Timeline

struct MusicEntry: TimelineEntry {
  let date: Date
  let state: WidgetState
  let fm: WidgetFmState
}

struct MusicProvider: TimelineProvider {
  func placeholder(in context: Context) -> MusicEntry {
    MusicEntry(date: Date(), state: WidgetState(), fm: WidgetFmState())
  }

  func getSnapshot(in context: Context, completion: @escaping (MusicEntry) -> Void) {
    completion(
      MusicEntry(date: Date(), state: WidgetState.load(), fm: WidgetFmState.load()))
  }

  func getTimeline(in context: Context, completion: @escaping (Timeline<MusicEntry>) -> Void) {
    let entry = MusicEntry(
      date: Date(), state: WidgetState.load(), fm: WidgetFmState.load())
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
    Group {
      if family == .systemMedium {
        fmLayout(entry.fm)
      } else {
        coverPlayerLayout(entry.state)
      }
    }
    .widgetBackground(background)
    // 兜底：iOS 15/16 点击非按钮区域打开 app（按钮区域 Link 优先）；
    // iOS 17+ 按钮走 AppIntent，其余区域同样能打开 app
    .widgetURL(URL(string: "md3music://widget/open"))
  }

  /// 组件背景层：小号 = 封面铺底 + 封面主色渐变遮罩（文字/按钮画在
  /// 内容层，遮罩负责对比度）；中号 = FM 卡纯色底（推送的 panelBg）。
  @ViewBuilder
  private var background: some View {
    if family == .systemMedium {
      entry.fm.panelBg
    } else {
      ZStack {
        if let image = entry.state.coverImage {
          Image(uiImage: image)
            .resizable()
            .scaledToFill()
        } else {
          Color(UIColor(entry.state.primary))
        }
        scrimGradient(entry.state)
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
      transportRow(s)
        .padding(.bottom, 14)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  // MARK: 中号：私人FM电台卡（1:1 对齐 Android widget_personal_fm）

  @ViewBuilder
  private func fmLayout(_ fm: WidgetFmState) -> some View {
    if fm.isLoggedIn {
      fmRadioCard(fm)
    } else {
      fmLoginCard(fm)
    }
  }

  /// 登录引导卡（未登录）：44 圆角图标 + 标题/副标题 + chevron，整卡可点。
  private func fmLoginCard(_ fm: WidgetFmState) -> some View {
    fmTappable(action: "fm_open_login") {
      HStack(spacing: 14) {
        ZStack {
          RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(fm.primaryContainer)
          Image(systemName: "antenna.radiowaves.left.and.right")
            .font(.system(size: 22))
            .foregroundColor(fm.onPrimaryContainer)
        }
        .frame(width: 44, height: 44)
        VStack(alignment: .leading, spacing: 2) {
          Text("登录后开启你的专属电台")
            .font(.system(size: 14, weight: .medium))
            .foregroundColor(fm.onSurface)
            .lineLimit(1)
            .truncationMode(.tail)
          Text("按你的口味不断续播")
            .font(.system(size: 12))
            .foregroundColor(fm.onSurfaceVariant)
            .lineLimit(1)
            .truncationMode(.tail)
        }
        Spacer(minLength: 0)
        Image(systemName: "chevron.right")
          .font(.system(size: 15, weight: .semibold))
          .foregroundColor(fm.onSurfaceVariant)
      }
      .padding(.horizontal, 20)
      .padding(.vertical, 18)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
  }

  /// 电台卡：左 112 大封面，右列 = 上排（歌名/歌手 + 收藏 + 播放）
  /// + 底排（预告封面 x3 + 档位按钮）。行高对齐 Android：48 + 16 + 48 = 112。
  private func fmRadioCard(_ fm: WidgetFmState) -> some View {
    HStack(spacing: 12) {
      fmCover(fm)
      VStack(spacing: 0) {
        HStack(spacing: 4) {
          VStack(alignment: .leading, spacing: 3) {
            Text(fm.title)
              .font(.system(size: 14, weight: .medium))
              .foregroundColor(fm.onSurface)
              .lineLimit(2)
              .truncationMode(.tail)
            if !fm.artist.isEmpty {
              Text(fm.artist)
                .font(.system(size: 12))
                .foregroundColor(fm.onSurfaceVariant)
                .lineLimit(1)
                .truncationMode(.tail)
            }
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
          fmFavoriteButton(fm)
          fmPlayButton(fm)
        }
        .frame(height: 48)
        HStack(spacing: 8) {
          ForEach(0..<3, id: \.self) { i in
            if !fm.nextHashes[i].isEmpty {
              fmNextSlot(fm, i)
            }
          }
          Spacer(minLength: 0)
          fmStationButton(fm)
        }
        .frame(height: 48)
        .padding(.top, 16)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  /// 当前封面 112 圆角 16（点击打开播放器页），无图回退音符占位。
  private func fmCover(_ fm: WidgetFmState) -> some View {
    fmTappable(action: "fm_open_player") {
      ZStack {
        if let image = fm.cover {
          Image(uiImage: image)
            .resizable()
            .scaledToFill()
        } else {
          Rectangle().fill(fm.surfaceHighest)
          Image(systemName: "music.note")
            .font(.system(size: 36))
            .foregroundColor(fm.onSurfaceVariant)
        }
      }
      .frame(width: 112, height: 112)
      .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
  }

  /// 收藏：已红心 primary 实心心，未红心 onSurfaceVariant 描边心。
  private func fmFavoriteButton(_ fm: WidgetFmState) -> some View {
    fmTappable(action: "fm_toggle_favorite") {
      Image(systemName: fm.isFavorite ? "heart.fill" : "heart")
        .font(.system(size: 22))
        .foregroundColor(fm.isFavorite ? fm.primary : fm.onSurfaceVariant)
        .frame(width: 48, height: 48)
    }
  }

  /// 播放/暂停：primary 圆底 + onPrimary 图标，加载中显示静态转圈
  /// （RemoteViews 的弧线动画在 SwiftUI 里同样不可用）。
  private func fmPlayButton(_ fm: WidgetFmState) -> some View {
    fmTappable(action: "fm_play_pause") {
      ZStack {
        Circle().fill(fm.primary)
        Image(
          systemName: fm.isLoading
            ? "arrow.triangle.2.circlepath" : (fm.isPlaying ? "pause.fill" : "play.fill")
        )
        .font(.system(size: 25, weight: .semibold))
        .foregroundColor(fm.onPrimary)
      }
      .frame(width: 48, height: 48)
    }
  }

  /// 预告封面槽 48 圆角 12：点击后台起播对应曲（命令带槽位编号，
  /// hash 由 Dart 侧按当前队列重算）。
  private func fmNextSlot(_ fm: WidgetFmState, _ i: Int) -> some View {
    fmTappable(action: "fm_open_track_\(i + 1)") {
      ZStack {
        if let image = fm.nextCovers[i] {
          Image(uiImage: image)
            .resizable()
            .scaledToFill()
        } else {
          Rectangle().fill(fm.surfaceHighest)
          Image(systemName: "music.note")
            .font(.system(size: 18))
            .foregroundColor(fm.onSurfaceVariant)
        }
      }
      .frame(width: 48, height: 48)
      .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
  }

  /// 档位按钮 40 圆钮：显示当前档位图标（0 红心/1 探索/2 小众/3 电台，
  /// SF Symbols 对应 Android 的四档叠放图标），点击循环切下一档。
  private func fmStationButton(_ fm: WidgetFmState) -> some View {
    let icons = [
      "heart.fill", "safari", "diamond", "antenna.radiowaves.left.and.right",
    ]
    let index = min(max(fm.stationIndex, 0), icons.count - 1)
    return fmTappable(action: "fm_select_station") {
      ZStack {
        Circle().fill(fm.surfaceHigh)
        Image(systemName: icons[index])
          .font(.system(size: 19))
          .foregroundColor(fm.onSurfaceVariant)
      }
      .frame(width: 40, height: 40)
    }
  }

  /// FM 卡点击热区：iOS 17+ AppIntent 直控，iOS 16 Link 打开 app 携带命令
  /// （iOS 15 整组件点按走 widgetURL 兜底）。
  @ViewBuilder
  private func fmTappable(
    action: String, @ViewBuilder content: () -> some View
  ) -> some View {
    if #available(iOSApplicationExtension 17.0, *) {
      switch action {
      case "fm_play_pause":
        Button(intent: FmPlayPauseIntent()) { content() }.buttonStyle(.plain)
      case "fm_toggle_favorite":
        Button(intent: FmToggleFavoriteIntent()) { content() }.buttonStyle(.plain)
      case "fm_select_station":
        Button(intent: FmSelectStationIntent()) { content() }.buttonStyle(.plain)
      case "fm_open_track_1":
        Button(intent: FmOpenTrack1Intent()) { content() }.buttonStyle(.plain)
      case "fm_open_track_2":
        Button(intent: FmOpenTrack2Intent()) { content() }.buttonStyle(.plain)
      case "fm_open_track_3":
        Button(intent: FmOpenTrack3Intent()) { content() }.buttonStyle(.plain)
      case "fm_open_login":
        Button(intent: FmOpenLoginIntent()) { content() }.buttonStyle(.plain)
      default:
        Button(intent: FmOpenPlayerIntent()) { content() }.buttonStyle(.plain)
      }
    } else {
      Link(destination: URL(string: "md3music://widget/\(action)")!) { content() }
    }
  }

  /// 三键行（小号封面播放器）：上一首 / 播放暂停 / 下一首，裸图标 +
  /// 白色半透明圆底播放键。
  private func transportRow(_ s: WidgetState) -> some View {
    HStack(spacing: 26) {
      transportButton(action: "previous") {
        Image(systemName: "backward.end.fill")
          .font(.system(size: 14, weight: .semibold))
          .foregroundColor(.white)
          .frame(width: 32, height: 32)
          .shadow(color: .black.opacity(0.35), radius: 2)
      }
      transportButton(action: "play_pause") {
        Image(systemName: s.isPlaying ? "pause.fill" : "play.fill")
          .font(.system(size: 16.8, weight: .semibold))
          .foregroundColor(Color(UIColor(white: 0.13, alpha: 1)))
          .frame(width: 40, height: 40)
          .background(Circle().fill(Color.white.opacity(0.82)))
      }
      transportButton(action: "next") {
        Image(systemName: "forward.end.fill")
          .font(.system(size: 14, weight: .semibold))
          .foregroundColor(.white)
          .frame(width: 32, height: 32)
          .shadow(color: .black.opacity(0.35), radius: 2)
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

// MARK: 私人FM卡命令（iOS 17+）：写 App Group 待 app 回前台转发 Dart
//（fm_open_track_N 不带参数，hash 由 Dart 按当前 FM 队列重算）

@available(iOSApplicationExtension 17.0, *)
struct FmPlayPauseIntent: AppIntent {
  static var title: LocalizedStringResource = "FM 播放 / 暂停"
  static var openAppWhenRun = true

  func perform() async throws -> some IntentResult {
    WidgetSyncBridge.writeCommand("fm_play_pause")
    return .result()
  }
}

@available(iOSApplicationExtension 17.0, *)
struct FmToggleFavoriteIntent: AppIntent {
  static var title: LocalizedStringResource = "FM 收藏"
  static var openAppWhenRun = true

  func perform() async throws -> some IntentResult {
    WidgetSyncBridge.writeCommand("fm_toggle_favorite")
    return .result()
  }
}

@available(iOSApplicationExtension 17.0, *)
struct FmSelectStationIntent: AppIntent {
  static var title: LocalizedStringResource = "FM 切换档位"
  static var openAppWhenRun = true

  func perform() async throws -> some IntentResult {
    WidgetSyncBridge.writeCommand("fm_select_station")
    return .result()
  }
}

@available(iOSApplicationExtension 17.0, *)
struct FmOpenTrack1Intent: AppIntent {
  static var title: LocalizedStringResource = "FM 起播预告曲 1"
  static var openAppWhenRun = true

  func perform() async throws -> some IntentResult {
    WidgetSyncBridge.writeCommand("fm_open_track_1")
    return .result()
  }
}

@available(iOSApplicationExtension 17.0, *)
struct FmOpenTrack2Intent: AppIntent {
  static var title: LocalizedStringResource = "FM 起播预告曲 2"
  static var openAppWhenRun = true

  func perform() async throws -> some IntentResult {
    WidgetSyncBridge.writeCommand("fm_open_track_2")
    return .result()
  }
}

@available(iOSApplicationExtension 17.0, *)
struct FmOpenTrack3Intent: AppIntent {
  static var title: LocalizedStringResource = "FM 起播预告曲 3"
  static var openAppWhenRun = true

  func perform() async throws -> some IntentResult {
    WidgetSyncBridge.writeCommand("fm_open_track_3")
    return .result()
  }
}

@available(iOSApplicationExtension 17.0, *)
struct FmOpenPlayerIntent: AppIntent {
  static var title: LocalizedStringResource = "FM 打开播放器"
  static var openAppWhenRun = true

  func perform() async throws -> some IntentResult {
    WidgetSyncBridge.writeCommand("fm_open_player")
    return .result()
  }
}

@available(iOSApplicationExtension 17.0, *)
struct FmOpenLoginIntent: AppIntent {
  static var title: LocalizedStringResource = "FM 去登录"
  static var openAppWhenRun = true

  func perform() async throws -> some IntentResult {
    WidgetSyncBridge.writeCommand("fm_open_login")
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
    .description("封面播放器（小）与私人FM电台卡（中）")
    .supportedFamilies([.systemSmall, .systemMedium])
  }
}

@main
struct MD3WidgetBundle: WidgetBundle {
  var body: some Widget {
    MD3MusicWidget()
  }
}
