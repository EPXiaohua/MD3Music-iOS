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
import ActivityKit

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

  /// 封面取色（对齐 Android CoverPlayerWidgetProvider 的 Palette 流程）：
  /// 缩到 24x24 统计——accent 取「有颜色」像素里最高频色相桶的平均
  /// 色相/饱和度/亮度（对应 vibrantSwatch），scrimBase 取全像素平均色
  /// （对应 dominantSwatch 近似，作遮罩基色）。近灰封面返回 nil。
  static func coverPalette(
    from image: UIImage?
  ) -> (accent: UIColor, scrimBase: UIColor)? {
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
    var bucketVal = [Double](repeating: 0, count: 24)
    var sumR = 0.0, sumG = 0.0, sumB = 0.0, samples = 0.0
    var colored = 0
    for i in stride(from: 0, to: pixels.count, by: 4) {
      let a = Double(pixels[i + 3]) / 255
      guard a > 0.5 else { continue }
      let r = Double(pixels[i]) / 255
      let g = Double(pixels[i + 1]) / 255
      let b = Double(pixels[i + 2]) / 255
      sumR += r
      sumG += g
      sumB += b
      samples += 1
      let mx = max(r, g, b)
      let mn = min(r, g, b)
      let v = mx
      let sat = mx == 0 ? 0 : (mx - mn) / mx
      // 跳过近黑/近白/低饱和像素，accent 只统计"有颜色"的部分
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
      bucketVal[bucket] += v
      colored += 1
    }
    guard colored > 8, samples > 0 else { return nil }
    var best = 0
    for i in 1..<24 where bucketCount[i] > bucketCount[best] { best = i }
    guard bucketCount[best] > 0 else { return nil }
    let hue = bucketHue[best] / Double(bucketCount[best])
    let sat = min(max(bucketSat[best] / Double(bucketCount[best]), 0.45), 0.85)
    // 亮度取桶内均值（vibrant 原色），不再强制 0.62
    let val = min(max(bucketVal[best] / Double(bucketCount[best]), 0.35), 0.80)
    let accent = UIColor(
      hue: CGFloat(hue), saturation: CGFloat(sat), brightness: CGFloat(val), alpha: 1)
    let scrimBase = UIColor(
      red: CGFloat(sumR / samples), green: CGFloat(sumG / samples),
      blue: CGFloat(sumB / samples), alpha: 1)
    return (accent, scrimBase)
  }
}

/// 小号封面播放器的取色结果（对齐 Android resolveAccent /
/// ensureAccentReadable）：accent = 播放键圆底，onAccent = 播放键图标色，
/// scrimBase = 遮罩渐变基色（封面主导色），scrimLight 决定文字用深/浅。
struct CoverPalette {
  var accent: UIColor
  var onAccent: UIColor
  var scrimBase: UIColor
  var scrimLight: Bool

  /// 无封面/近灰封面兜底：主题色按钮 + 深色遮罩（Android 同策略，
  /// scrim 兜底色 0xFF10131A）。
  static func fallback(primary: UIColor, onPrimary: UIColor) -> CoverPalette {
    let base = UIColor(red: 0x10 / 255, green: 0x13 / 255, blue: 0x1A / 255, alpha: 1)
    return CoverPalette(
      accent: primary, onAccent: onPrimary, scrimBase: base,
      scrimLight: luminance(base) > 0.5)
  }

  static func resolve(
    image: UIImage?, primary: UIColor, onPrimary: UIColor
  ) -> CoverPalette {
    guard let raw = WidgetState.coverPalette(from: image) else {
      return fallback(primary: primary, onPrimary: onPrimary)
    }
    let readable = ensureAccentReadable(raw.accent, scrimBase: raw.scrimBase)
    let on: UIColor =
      luminance(readable) > 0.5
      ? UIColor(red: 0x1D / 255, green: 0x1B / 255, blue: 0x20 / 255, alpha: 1)
      : .white
    return CoverPalette(
      accent: readable, onAccent: on, scrimBase: raw.scrimBase,
      scrimLight: luminance(raw.scrimBase) > 0.5)
  }

  /// sRGB 相对亮度（同 Android ColorUtils.calculateLuminance）。
  static func luminance(_ color: UIColor) -> CGFloat {
    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    color.getRed(&r, green: &g, blue: &b, alpha: &a)
    func linear(_ c: CGFloat) -> CGFloat {
      c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
  }

  /// accent 与遮罩底色亮度差不足 0.20 时，保持色相不变，把亮度往白/黑
  /// 方向 blend 拉开到 0.30（clamp 0.10~0.75），保证播放键在遮罩上可读。
  private static func ensureAccentReadable(
    _ accent: UIColor, scrimBase: UIColor
  ) -> UIColor {
    var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    accent.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
    let lumBase = luminance(scrimBase)
    if abs(luminance(accent) - lumBase) >= 0.20 { return accent }
    let brighten = lumBase < 0.5
    var lo: CGFloat = 0.10, hi: CGFloat = 0.75
    var best = UIColor(hue: h, saturation: s, brightness: brighten ? hi : lo, alpha: 1)
    for _ in 0..<12 {
      let mid = (lo + hi) / 2
      let candidate = UIColor(hue: h, saturation: s, brightness: mid, alpha: 1)
      let ok = abs(luminance(candidate) - lumBase) >= 0.30
      if brighten {
        if ok { hi = mid; best = candidate } else { lo = mid }
      } else {
        if ok { lo = mid; best = candidate } else { hi = mid }
      }
    }
    return best
  }

  /// 文本色随遮罩明暗（对齐 Android：亮遮罩深墨字 0xE610131A、暗遮罩
  /// 白字 0xF2FFFFFF）。
  var textColor: Color {
    scrimLight
      ? Color(red: 0x10 / 255, green: 0x13 / 255, blue: 0x1A / 255).opacity(0.90)
      : Color.white.opacity(0.95)
  }
  var subTextColor: Color {
    scrimLight
      ? Color(red: 0x10 / 255, green: 0x13 / 255, blue: 0x1A / 255).opacity(0.60)
      : Color.white.opacity(0.70)
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
    .widgetContentInset()
    .widgetBackground(background)
    // 兜底：iOS 15 全尺寸 + iOS 16 小号（small 不支持 Link 多交互区域）
    // 整卡点按 = 播放/暂停；其余打开 app（按钮区域 Link/Button 优先）
    .widgetURL(URL(string: fallbackTapURL))
  }

  /// 整组件点按兜底 URL：iOS 17+ 全尺寸与 iOS 16 medium/large 打开 app；
  /// iOS 16 及以下小号因不支持多交互区域，整卡点击 = 播放/暂停。
  private var fallbackTapURL: String {
    if #available(iOSApplicationExtension 17.0, *) { return "md3music://widget/open" }
    return family == .systemSmall
      ? "md3music://widget/play_pause" : "md3music://widget/open"
  }

  /// 小号取色（对齐 Android resolveAccent：封面 vibrant + 可读性修正，
  /// 无封面回退主题色 primary/onPrimary）。
  private var coverPalette: CoverPalette {
    CoverPalette.resolve(
      image: entry.state.coverImage,
      primary: UIColor(entry.state.primary),
      onPrimary: UIColor(entry.state.onPrimary))
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
        scrimGradient(coverPalette)
      }
      .clipped()
    }
  }

  /// 遮罩：封面主导色自上而下加深（顶 20% 透出封面 → 底 88% 保证文字/
  /// 按钮可读，对齐 Android scrim 渐变 alpha 0x33 → 0xE0）。
  private func scrimGradient(_ palette: CoverPalette) -> some View {
    LinearGradient(
      stops: [
        .init(color: Color(palette.scrimBase).opacity(0.20), location: 0),
        .init(color: Color(palette.scrimBase).opacity(0.88), location: 1),
      ],
      startPoint: .top, endPoint: .bottom)
  }

  /// 小号（Android 2x2 封面播放器）：中部歌名/歌手，底部三键。文字色
  /// 随遮罩明暗切换（不再加阴影，可读性由遮罩保证）。
  private func coverPlayerLayout(_ s: WidgetState) -> some View {
    let palette = coverPalette
    return VStack(spacing: 0) {
      Spacer(minLength: 0)
      VStack(spacing: 3) {
        Text(s.title.isEmpty ? "MD3Music" : s.title)
          .font(.system(size: 12, weight: .semibold))
          .foregroundColor(palette.textColor)
          .lineLimit(1)
          .truncationMode(.tail)
        Text(s.artist.isEmpty ? "未在播放" : s.artist)
          .font(.system(size: 10))
          .foregroundColor(palette.subTextColor)
          .lineLimit(1)
          .truncationMode(.tail)
      }
      .padding(.horizontal, 12)
      Spacer(minLength: 0)
      transportRow(s, palette: palette)
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

  /// 电台卡：左大封面，右列 = 上排（歌名/歌手 + 收藏 + 播放）+ 底排
  /// （预告封面 x3 + 档位按钮）。按可用高度自适应：封面 84~104、上下
  /// 排高 = (封面 - 14) / 2，保证内容不贴组件边缘被裁。
  private func fmRadioCard(_ fm: WidgetFmState) -> some View {
    GeometryReader { geo in
      let coverSize = min(max(geo.size.height - 32, 84), 104)
      let rowHeight = (coverSize - 14) / 2
      HStack(spacing: 12) {
        fmCover(fm, size: coverSize)
        VStack(spacing: 0) {
          HStack(spacing: 4) {
            VStack(alignment: .leading, spacing: 3) {
              Text(fm.title)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(fm.onSurface)
                .lineLimit(rowHeight < 42 ? 1 : 2)
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
            fmFavoriteButton(fm, size: rowHeight)
            fmPlayButton(fm, size: rowHeight)
          }
          .frame(height: rowHeight)
          HStack(spacing: 8) {
            ForEach(0..<3, id: \.self) { i in
              if !fm.nextHashes[i].isEmpty {
                fmNextSlot(fm, i, size: rowHeight)
              }
            }
            Spacer(minLength: 0)
            fmStationButton(fm, size: rowHeight * 0.8)
          }
          .frame(height: rowHeight)
          .padding(.top, 14)
        }
        .frame(height: coverSize)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  /// 当前封面（点击打开播放器页），无图回退音符占位。尺寸随卡片高度自适应。
  private func fmCover(_ fm: WidgetFmState, size: CGFloat) -> some View {
    fmTappable(action: "fm_open_player") {
      ZStack {
        if let image = fm.cover {
          Image(uiImage: image)
            .resizable()
            .scaledToFill()
        } else {
          Rectangle().fill(fm.surfaceHighest)
          Image(systemName: "music.note")
            .font(.system(size: size * 0.32))
            .foregroundColor(fm.onSurfaceVariant)
        }
      }
      .frame(width: size, height: size)
      .clipShape(RoundedRectangle(cornerRadius: size * 0.143, style: .continuous))
    }
  }

  /// 收藏：已红心 primary 实心心，未红心 onSurfaceVariant 描边心。
  private func fmFavoriteButton(_ fm: WidgetFmState, size: CGFloat) -> some View {
    fmTappable(action: "fm_toggle_favorite") {
      Image(systemName: fm.isFavorite ? "heart.fill" : "heart")
        .font(.system(size: size * 0.46))
        .foregroundColor(fm.isFavorite ? fm.primary : fm.onSurfaceVariant)
        .frame(width: size, height: size)
    }
  }

  /// 播放/暂停：primary 圆底 + onPrimary 图标，加载中显示静态转圈
  /// （RemoteViews 的弧线动画在 SwiftUI 里同样不可用）。
  private func fmPlayButton(_ fm: WidgetFmState, size: CGFloat) -> some View {
    fmTappable(action: "fm_play_pause") {
      ZStack {
        Circle().fill(fm.primary)
        Image(
          systemName: fm.isLoading
            ? "arrow.triangle.2.circlepath" : (fm.isPlaying ? "pause.fill" : "play.fill")
        )
        .font(.system(size: size * 0.52, weight: .semibold))
        .foregroundColor(fm.onPrimary)
      }
      .frame(width: size, height: size)
    }
  }

  /// 预告封面槽：点击后台起播对应曲（命令带槽位编号，
  /// hash 由 Dart 侧按当前队列重算）。
  private func fmNextSlot(_ fm: WidgetFmState, _ i: Int, size: CGFloat) -> some View {
    fmTappable(action: "fm_open_track_\(i + 1)") {
      ZStack {
        if let image = fm.nextCovers[i] {
          Image(uiImage: image)
            .resizable()
            .scaledToFill()
        } else {
          Rectangle().fill(fm.surfaceHighest)
          Image(systemName: "music.note")
            .font(.system(size: size * 0.375))
            .foregroundColor(fm.onSurfaceVariant)
        }
      }
      .frame(width: size, height: size)
      .clipShape(RoundedRectangle(cornerRadius: size * 0.25, style: .continuous))
    }
  }

  /// 档位按钮（0 红心/1 探索/2 小众/3 电台，SF Symbols 对应 Android 的
  /// 四档叠放图标），点击循环切下一档。
  private func fmStationButton(_ fm: WidgetFmState, size: CGFloat) -> some View {
    let icons = [
      "heart.fill", "safari", "diamond", "antenna.radiowaves.left.and.right",
    ]
    let index = min(max(fm.stationIndex, 0), icons.count - 1)
    return fmTappable(action: "fm_select_station") {
      ZStack {
        Circle().fill(fm.surfaceHigh)
        Image(systemName: icons[index])
          .font(.system(size: size * 0.475))
          .foregroundColor(fm.onSurfaceVariant)
      }
      .frame(width: size, height: size)
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

  /// 三键行（小号封面播放器）：上一首 / 播放暂停 / 下一首。上一首/下一首
  /// 图标 = 文本色；播放键圆底 = 封面 accent，图标随圆底明暗取深墨/白
  /// （对齐 Android resolveAccent 的 onAccent）。
  private func transportRow(_ s: WidgetState, palette: CoverPalette) -> some View {
    HStack(spacing: 26) {
      transportButton(action: "previous") {
        Image(systemName: "backward.end.fill")
          .font(.system(size: 14, weight: .semibold))
          .foregroundColor(palette.textColor)
          .frame(width: 32, height: 32)
      }
      transportButton(action: "play_pause") {
        Image(systemName: s.isPlaying ? "pause.fill" : "play.fill")
          .font(.system(size: 16.8, weight: .semibold))
          .foregroundColor(Color(palette.onAccent))
          .frame(width: 40, height: 40)
          .background(Circle().fill(Color(palette.accent)))
      }
      transportButton(action: "next") {
        Image(systemName: "forward.end.fill")
          .font(.system(size: 14, weight: .semibold))
          .foregroundColor(palette.textColor)
          .frame(width: 32, height: 32)
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

  /// iOS 15/16 内容层安全边距：widgetBackground 用负 padding 把背景外扩
  /// 铺满组件时，内容层也跟着外扩到组件边缘——加回 16pt 抵消，避免文字/
  /// 按钮贴边被裁（iOS 17+ containerBackground 自带 content margin，不需要）。
  @ViewBuilder
  func widgetContentInset() -> some View {
    if #available(iOSApplicationExtension 17.0, *) {
      self
    } else {
      padding(16)
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

// MARK: - 锁屏歌词 Live Activity（iOS 16.1+）
//
// 对齐 Android LockScreenLyricActivity 的视觉与数据协议（AM 风格）：
// - 背景 = 模糊封面（App 侧预处理写 la_cover_blur.png）+ 40% 黑遮罩
// - 头部「歌名 · 歌手」居中（白 70%）；无歌词时中央占位文案（白 40%）
// - 歌词带：上一行/下一行暗态（白 20%），当前行亮（白 92%，动态取色 =
//   85% 白 + 15% 封面主色），副行翻译/罗马音（白 50%，字号 ×0.7）
// - 逐字卡拉OK：逐词到点由暗翻亮（Android 为平滑掩码，Live Activity
//   无逐像素裁剪能力，逐词翻色是同级实现）
// - 底部进度条：宽 72%、高 4pt、底白 20%、面白，与 Android 一致
//
// 数据：ContentState 只带轻量状态（行下标/位置/播放态/样式），整首歌词
// 从 App Group 的 la_lyrics.json 读取（App 侧 LyricLiveActivityController
// 写入；结构定义与 Runner 侧副本字段一致，本项目惯例两侧各复制一份）。
//  位置由 TimelineView 按墙钟自推进（positionMs + now - updatedAt），暂停
//  时冻结；切行由 App 推送。15fps 上限省电（逐词翻色足够平滑）。

/// 锁屏歌词 Live Activity 属性（Runner 侧 LyricLiveActivityController.swift
/// 内有一份必须同步的字段定义）
@available(iOSApplicationExtension 16.1, *)
struct LyricLiveActivityAttributes: ActivityAttributes {
  public struct ContentState: Codable, Hashable {
    var songId: String
    var rev: Int
    var lineIndex: Int
    var positionMs: Int
    var durationMs: Int
    var isPlaying: Bool
    var updatedAt: Date
    var placeholder: String
    var title: String
    var artist: String
    var accent: Int
    var useDynamic: Bool
    var showSub: Bool
    var fontSize: Double
  }

  var sessionKey: String
}

/// la_lyrics.json 的单行（与 Android 锁屏歌词协议同构：words/wordStarts/
/// wordDurations 平行数组）
struct LyricLiveLine {
  var text = ""
  var startMs = 0
  var durMs = 0
  /// (text, startMs, durMs)
  var words: [(String, Int, Int)] = []
  var sub = ""

  static func parse(_ raw: [String: Any]) -> LyricLiveLine {
    var l = LyricLiveLine()
    l.text = raw["text"] as? String ?? ""
    l.startMs = (raw["start"] as? NSNumber)?.intValue ?? 0
    l.durMs = (raw["duration"] as? NSNumber)?.intValue ?? 0
    let texts = raw["words"] as? [Any] ?? []
    let starts = raw["wordStarts"] as? [Any] ?? []
    let durs = raw["wordDurations"] as? [Any] ?? []
    for i in 0..<texts.count {
      let t = texts[i] as? String ?? ""
      let s = i < starts.count ? ((starts[i] as? NSNumber)?.intValue ?? 0) : 0
      let d = i < durs.count ? ((durs[i] as? NSNumber)?.intValue ?? 0) : 0
      l.words.append((t, s, d))
    }
    l.sub = raw["sub"] as? String ?? ""
    return l
  }
}

/// 歌词文件缓存：songId/rev 变化才重读（TimelineView 高频重渲染不能带文件 IO）
enum LyricLiveStore {
  static var cachedSongId: String?
  static var cachedRev = -1
  static var lines: [LyricLiveLine] = []
  static var coverBlur: UIImage?
  static var coverBlurLoaded = false

  static func load(songId: String, rev: Int) {
    if cachedSongId == songId && cachedRev == rev { return }
    cachedSongId = songId
    cachedRev = rev
    lines = []
    let groupId = WidgetSyncBridge.resolvedAppGroupId
    guard
      let container = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: groupId),
      let fileData = try? Data(
        contentsOf: container.appendingPathComponent("la_lyrics.json")),
      let obj = try? JSONSerialization.jsonObject(with: fileData) as? [String: Any],
      let rawLines = obj["lines"] as? [Any]
    else { return }
    lines = rawLines.compactMap { $0 as? [String: Any] }.map { LyricLiveLine.parse($0) }
  }

  /// 加载并返回当前歌词行（灵动岛展开区用：ViewBuilder 闭包里不能有
  /// 裸函数调用语句，只能放 let 声明 + 视图）
  static func currentLines(songId: String, rev: Int) -> [LyricLiveLine] {
    load(songId: songId, rev: rev)
    return lines
  }

  /// 模糊封面（懒加载一次；App 侧按 songId 重写，rev 无关）
  static func coverImage() -> UIImage? {
    if coverBlurLoaded { return coverBlur }
    coverBlurLoaded = true
    let groupId = WidgetSyncBridge.resolvedAppGroupId
    guard
      let container = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: groupId)
    else { return nil }
    coverBlur = UIImage(
      contentsOfFile: container.appendingPathComponent("la_cover_blur.png").path)
    return coverBlur
  }
}

@available(iOSApplicationExtension 16.1, *)
struct LyricLockScreenView: View {
  var state: LyricLiveActivityAttributes.ContentState

  /// 当前实际位置（ms）：播放中按墙钟推进，暂停时静止
  func positionMs(at date: Date) -> Int {
    guard state.isPlaying else { return state.positionMs }
    let elapsed = Int(date.timeIntervalSince(state.updatedAt) * 1000)
    return min(
      state.positionMs + max(0, elapsed), max(state.durationMs, 1))
  }

  /// 当前行亮色：动态取色 = 85% 白 + 15% 封面主色（对齐 Android
  /// mixWhiteAccent dimMixRatio 0.15），否则纯白
  var brightColor: Color {
    guard state.useDynamic, state.accent != 0 else { return .white }
    let argb = state.accent
    let r = Double((argb >> 16) & 0xFF), g = Double((argb >> 8) & 0xFF),
      b = Double(argb & 0xFF)
    let mix = 0.15
    return Color(
      red: (255 * (1 - mix) + r * mix) / 255,
      green: (255 * (1 - mix) + g * mix) / 255,
      blue: (255 * (1 - mix) + b * mix) / 255)
  }

  /// 背景层：模糊封面铺底 + 40% 黑遮罩（对齐 Android 0x66000000）；
  /// 无图回退纯黑（Android 同兜底 0xFF000000）
  var backgroundLayer: some View {
    ZStack {
      if let cover = LyricLiveStore.coverImage() {
        GeometryReader { geo in
          Image(uiImage: cover)
            .resizable()
            .scaledToFill()
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
      } else {
        Color.black
      }
      Color.black.opacity(0.4)
    }
  }

  var body: some View {
    // 歌词内容：TimelineView 驱动逐字/进度本地推进（暂停冻结；15fps 省电）
    let content = TimelineView(
      .animation(minimumInterval: 1.0 / 15.0, paused: !state.isPlaying)
    ) { timeline in
      VStack(spacing: 0) {
        header
        lyricBand(at: timeline.date)
        ProgressBarLive(
          position: positionMs(at: timeline.date), duration: state.durationMs
        )
        .padding(.bottom, 14)
      }
    }
    // iOS 16.2+ 走 containerBackground（placement 只有 .widget 一档，
    // Live Activity 同样用它）；16.1 全幅铺
    if #available(iOSApplicationExtension 16.2, *) {
      content.containerBackground(for: .widget) { backgroundLayer }
    } else {
      content.background(backgroundLayer)
    }
  }

  /// 头部「歌名 · 歌手」居中（对齐 Android header 13pt 白 70%）
  private var header: some View {
    Text(state.artist.isEmpty ? state.title : "\(state.title) · \(state.artist)")
      .font(.system(size: 13, weight: .medium))
      .foregroundColor(.white.opacity(0.70))
      .lineLimit(1)
      .truncationMode(.tail)
      .padding(.top, 14)
  }

  /// 歌词带：上一行（暗）/ 当前行（亮 + 逐字 + 副行）/ 下一行（暗）
  @ViewBuilder
  func lyricBand(at date: Date) -> some View {
    let pos = positionMs(at: date)
    let lines = LyricLiveStore.lines
    let idx = state.lineIndex
    let size = min(max(state.fontSize, 13), 20)
    if lines.isEmpty || idx < 0 || idx >= lines.count {
      // 无歌词：占位文案居中（白 40%，对齐 Android placeholder 0x66FFFFFF）
      Spacer()
      if !state.placeholder.isEmpty {
        Text(state.placeholder)
          .font(.system(size: 15))
          .foregroundColor(.white.opacity(0.40))
          .multilineTextAlignment(.center)
          .padding(.horizontal, 20)
      }
      Spacer()
    } else {
      VStack(alignment: .leading, spacing: 0) {
        if idx > 0 {
          Text(lines[idx - 1].text)
            .font(.system(size: size))
            .foregroundColor(.white.opacity(0.20))
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.bottom, 6)
        }
        currentLineView(lines[idx], pos: pos, size: size)
        if idx + 1 < lines.count {
          Text(lines[idx + 1].text)
            .font(.system(size: size))
            .foregroundColor(.white.opacity(0.20))
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.top, 6)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      Spacer()
    }
  }

  /// 当前行：逐词翻亮（词起始时间到点由暗 20% 翻亮色）；无逐字时间轴的
  /// 行整行亮色。副行（翻译/罗马音）跟随（白 50%，字号 ×0.7）。
  @ViewBuilder
  func currentLineView(_ line: LyricLiveLine, pos: Int, size: CGFloat) -> some View {
    let subSize = max(size * 0.7, 11)
    VStack(alignment: .leading, spacing: 2) {
      if line.words.isEmpty {
        Text(line.text)
          .font(.system(size: size, weight: .semibold))
          .foregroundColor(brightColor.opacity(0.92))
          .lineLimit(3)
          .truncationMode(.tail)
      } else {
        wordFlow(line, pos: pos, size: size)
      }
      if state.showSub, !line.sub.isEmpty {
        Text(line.sub)
          .font(.system(size: subSize))
          .foregroundColor(.white.opacity(0.50))
          .lineLimit(2)
          .truncationMode(.tail)
          .padding(.top, 2)
      }
    }
  }

  /// 逐词流式排布：词到点翻亮，未到点暗 20%（Text 拼接，同一行内自动换行）
  func wordFlow(_ line: LyricLiveLine, pos: Int, size: CGFloat) -> some View {
    var content = Text("")
    var first = true
    for (text, start, _) in line.words {
      let style =
        pos >= start
        ? brightColor.opacity(0.92)
        : Color.white.opacity(0.20)
      let piece = Text(text)
        .font(.system(size: size, weight: .semibold))
        .foregroundColor(style)
      content = first ? piece : content + piece
      first = false
    }
    return content.lineLimit(3)
  }
}

/// 进度条：宽 ≈72% 居中、高 4pt、底白 20%、面白（对齐 Android drawProgress）
struct ProgressBarLive: View {
  var position: Int
  var duration: Int

  var body: some View {
    let ratio =
      duration > 0
      ? min(max(Double(position) / Double(duration), 0), 1) : 0
    GeometryReader { geo in
      ZStack(alignment: .leading) {
        Capsule().fill(Color.white.opacity(0.20))
        Capsule().fill(Color.white)
          .frame(width: max(0, geo.size.width * ratio))
      }
    }
    .frame(height: 4)
    .padding(.horizontal, 56)
  }
}

/// 锁屏歌词 Live Activity 声明（锁屏卡 + 灵动岛）
@available(iOSApplicationExtension 16.1, *)
struct LyricLiveActivityWidget: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: LyricLiveActivityAttributes.self) { context in
      LyricLockScreenView(state: context.state)
    } dynamicIsland: { context in
      DynamicIsland {
        // 展开区：头部 + 当前行（含副行）+ 进度，与锁屏卡同一数据
        DynamicIslandExpandedRegion(.leading) {
          Image(systemName: "music.note")
            .font(.system(size: 16))
            .foregroundColor(.white.opacity(0.7))
        }
        DynamicIslandExpandedRegion(.trailing) {
          Text(context.state.isPlaying ? "播放中" : "已暂停")
            .font(.system(size: 12))
            .foregroundColor(.white.opacity(0.7))
        }
        DynamicIslandExpandedRegion(.center) {
          Text(
            context.state.artist.isEmpty
              ? context.state.title
              : "\(context.state.title) · \(context.state.artist)"
          )
          .font(.system(size: 13, weight: .medium))
          .foregroundColor(.white.opacity(0.85))
          .lineLimit(1)
        }
        DynamicIslandExpandedRegion(.bottom) {
          let lines = LyricLiveStore.currentLines(
            songId: context.state.songId, rev: context.state.rev)
          let idx = context.state.lineIndex
          Group {
            if lines.isEmpty || idx < 0 || idx >= lines.count {
              Text(
                lines.isEmpty && !context.state.placeholder.isEmpty
                  ? context.state.placeholder : ""
              )
              .font(.system(size: 14))
              .foregroundColor(.white.opacity(0.4))
            } else {
              VStack(alignment: .leading, spacing: 2) {
                Text(lines[idx].text)
                  .font(.system(size: 15, weight: .semibold))
                  .foregroundColor(.white.opacity(0.92))
                  .lineLimit(2)
                if context.state.showSub, !lines[idx].sub.isEmpty {
                  Text(lines[idx].sub)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.5))
                    .lineLimit(1)
                }
              }
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      } compactLeading: {
        Image(systemName: "music.note")
          .foregroundColor(.white)
      } compactTrailing: {
        Image(systemName: context.state.isPlaying ? "waveform" : "pause.fill")
          .foregroundColor(.white.opacity(0.8))
      } minimal: {
        Image(systemName: "music.note")
          .foregroundColor(.white)
      }
      .widgetURL(URL(string: "md3music://widget/open"))
    }
  }
}

@main
struct MD3WidgetBundle: WidgetBundle {
  var body: some Widget {
    MD3MusicWidget()
    if #available(iOSApplicationExtension 16.1, *) {
      LyricLiveActivityWidget()
    }
  }
}
