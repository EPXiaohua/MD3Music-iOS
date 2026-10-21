//
//  LyricLiveActivityController.swift
//  Runner
//
//  iOS 锁屏歌词（Live Activity）。对齐 Android LockScreenLyricActivity 的
//  数据协议与视觉（AM 风格：模糊封面底 + 40% 黑遮罩、逐字卡拉OK、
//  动态取色 85% 白 + 15% 主色、副行翻译）。
//
//  数据分两层（ContentState 只放轻量状态，重歌词走 App Group 文件）：
//  - la_lyrics.json（App Group）：整首歌词 + songId + rev，整包变化时重写；
//  - ContentState：songId/rev/行下标/位置/播放态/样式色，行变化时更新；
//    扩展侧 TimelineView 按墙钟自推进位置，行内逐字进度本地计算，
//    Dart 端只需在切行/seek/暂停时推 ContentState（服务内去重）。
//
//  封面模糊图：songId 变化时从 App Group 里的 widget_cover.png
//  （WidgetSync 维护）做小图高斯模糊写 la_cover_blur.png，扩展直接加载，
//  不在扩展渲染路径做模糊。
//
//  Attributes/ContentState 结构与 MD3Widget.swift 内的扩展侧副本
//  必须保持字段一致（本项目惯例：共享 Swift 代码两侧各复制一份，
//  不走 pbxproj 共享编译）。
//
//  注意：需 App 的 Info.plist 声明 NSSupportsLiveActivities；本机
//  iOS < 16.1 时所有调用安静返回 false，Dart 侧开关无效但不报错。
//

import Flutter
import UIKit
import ActivityKit

/// Live Activity 属性（Runner 侧副本；MD3Widget.swift 内有一份必须同步的字段定义）
@available(iOS 16.1, *)
struct LyricLiveActivityAttributes: ActivityAttributes {
  public struct ContentState: Codable, Hashable {
    /// 当前歌 id（对应 la_lyrics.json 的 songId）
    var songId: String
    /// 歌词文件版本（整包重推时 +1，扩展据此重读文件）
    var rev: Int
    /// 当前行下标（-1 = 无歌词/占位）
    var lineIndex: Int
    /// ContentState 写入时刻的播放位置（ms），扩展按墙钟自推进
    var positionMs: Int
    var durationMs: Int
    var isPlaying: Bool
    /// 状态写入时刻（墙钟），自推进基准
    var updatedAt: Date
    /// 歌词未就绪时的占位文案
    var placeholder: String
    /// 头部「歌名 · 歌手」
    var title: String
    var artist: String
    /// 封面主色（ARGB Int，0 = 无）；useDynamic 时当前行亮色 = 85% 白 + 15% 主色
    var accent: Int
    var useDynamic: Bool
    /// 副行（翻译/罗马音）开关（Dart 侧已按 displayMode 选好 sub 内容）
    var showSub: Bool
    /// 主行字号（安卓锁屏歌词设置透传，扩展侧 clamp）
    var fontSize: Double
  }

  /// 每次播放会话固定；切歌不换 Attributes（走 ContentState），避免重建活动
  var sessionKey: String
}

@objc final class LyricLiveActivityController: NSObject {
  static let shared = LyricLiveActivityController()
  private static let channelName = "com.md3music.md3music/lyric_live_activity"

  private var channel: FlutterMethodChannel?
  private var activity: Activity<LyricLiveActivityAttributes>?
  private var lastBlurSongId: String?

  func attach(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: Self.channelName, binaryMessenger: messenger)
    channel?.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard #available(iOS 16.1, *) else {
      // 低版本：开关无效但不报错（Dart 侧照常走流程）
      result(false)
      return
    }
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "setEnabled":
      let enabled = args["enabled"] as? Bool ?? false
      if !enabled { endAll() }
      result(true)
    case "setLyrics":
      handleSetLyrics(args, result: result)
    case "update":
      handleUpdate(args, result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - 歌词文件（App Group）

  private func appGroupContainer() -> URL? {
    // 与 WidgetSync 相同的免签名工具兼容策略：优先读签名里声明的 group
    let declared = "group.com.md3music.md3music"
    var candidates = [declared]
    if let signed = signedAppGroups() {
      for g in signed where !candidates.contains(g) { candidates.append(g) }
    }
    for g in candidates {
      if let url = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: g)
      {
        return url
      }
    }
    return nil
  }

  private func signedAppGroups() -> [String]? {
    guard
      let security = dlopen(
        "/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY),
      let createSym = dlsym(security, "SecTaskCreateFromSelf"),
      let copySym = dlsym(security, "SecTaskCopyValueForEntitlement")
    else { return nil }
    typealias CreateFn = @convention(c) (CFAllocator?) -> OpaquePointer?
    typealias CopyFn =
      @convention(c) (OpaquePointer?, CFString, UnsafeMutableRawPointer?) -> CFTypeRef?
    guard let task = unsafeBitCast(createSym, to: CreateFn.self)(nil) else { return nil }
    guard
      let value = unsafeBitCast(copySym, to: CopyFn.self)(
        task, "com.apple.security.application-groups" as CFString, nil)
    else { return nil }
    return (value as? [Any])?.compactMap { $0 as? String }
  }

  /// 整包歌词：写 la_lyrics.json（{"songId","lines":[...]}）。
  /// lines 与 Android 锁屏歌词协议同构（text/start/duration/words/
  /// wordStarts/wordDurations/sub），由 Dart 侧原样透传。
  private func handleSetLyrics(_ args: [String: Any], result: @escaping FlutterResult) {
    let songId = args["songId"] as? String ?? ""
    guard let lines = args["lines"] as? [Any] else {
      result(false)
      return
    }
    guard let dir = appGroupContainer() else {
      result(false)
      return
    }
    let payload: [String: Any] = [
      "songId": songId,
      "lines": lines,
    ]
    guard
      JSONSerialization.isValidJSONObject(payload),
      let data = try? JSONSerialization.data(withJSONObject: payload)
    else {
      result(false)
      return
    }
    let url = dir.appendingPathComponent("la_lyrics.json")
    do {
      try data.write(to: url, options: .atomic)
    } catch {
      NSLog("[LyricLiveActivity] write lyrics failed: \(error)")
      result(false)
      return
    }
    // 封面模糊图：songId 变化才重做（低频）
    if lastBlurSongId != songId {
      lastBlurSongId = songId
      writeBlurredCover(to: dir)
    }
    result(true)
  }

  /// widget_cover.png（WidgetSync 维护的当前封面）→ 缩到 120px → 高斯模糊
  /// （外扩 5σ 防 Deep 边缘黑线，与 PiP 同法）→ 写 la_cover_blur.png。
  private func writeBlurredCover(to dir: URL) {
    DispatchQueue.global(qos: .utility).async {
      let src = dir.appendingPathComponent("widget_cover.png")
      guard let image = UIImage(contentsOfFile: src.path), let cg = image.cgImage else {
        return  // 无封面：扩展侧回退纯黑底
      }
      // 缩到最长边 120px（模糊后无细节损失，成本极低）
      let maxSide: CGFloat = 120
      let scale = min(1, maxSide / CGFloat(max(cg.width, cg.height)))
      let w = max(1, Int(CGFloat(cg.width) * scale))
      let h = max(1, Int(CGFloat(cg.height) * scale))
      guard let small = cg.resized(toWidth: w, height: h) else { return }
      let radius = 12
      let pad = radius * 5
      let cw = w + pad * 2, ch = h + pad * 2
      guard
        let ctx = CGContext(
          data: nil, width: cw, height: ch, bitsPerComponent: 8, bytesPerRow: 0,
          space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      else { return }
      // 铺实色黑底（防半透明带），中置封面（边缘外即黑，等效 clamp 深色）
      ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
      ctx.fill(CGRect(x: 0, y: 0, width: cw, height: ch))
      ctx.draw(small, in: CGRect(x: pad, y: pad, width: w, height: h))
      guard let padded = ctx.makeImage() else { return }
      let ciImage = CIImage(cgImage: padded)
        .clampedToExtent()
        .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: Double(radius)])
        .cropped(to: CGRect(x: pad, y: pad, width: w, height: h))
      let outCtx = CIContext(options: [.useSoftwareRenderer: false])
      guard let out = outCtx.createCGImage(ciImage, from: ciImage.extent) else { return }
      let outImage = UIImage(cgImage: out)
      try? outImage.pngData()?.write(
        to: dir.appendingPathComponent("la_cover_blur.png"), options: .atomic)
    }
  }

  // MARK: - 活动生命周期

  /// 轻量状态更新：无活动则请求，有则更新 ContentState。
  private func handleUpdate(_ args: [String: Any], result: @escaping FlutterResult) {
    let state = LyricLiveActivityAttributes.ContentState(
      songId: args["songId"] as? String ?? "",
      rev: args["rev"] as? Int ?? 0,
      lineIndex: args["lineIndex"] as? Int ?? -1,
      positionMs: args["positionMs"] as? Int ?? 0,
      durationMs: args["durationMs"] as? Int ?? 0,
      isPlaying: args["isPlaying"] as? Bool ?? false,
      updatedAt: Date(),
      placeholder: args["placeholder"] as? String ?? "",
      title: args["title"] as? String ?? "",
      artist: args["artist"] as? String ?? "",
      accent: args["accent"] as? Int ?? 0,
      useDynamic: args["useDynamic"] as? Bool ?? true,
      showSub: args["showSub"] as? Bool ?? true,
      fontSize: args["fontSize"] as? Double ?? 16
    )
    if let activity = activity {
      Task {
        await activity.update(state)
      }
      result(true)
      return
    }
    do {
      let attributes = LyricLiveActivityAttributes(
        sessionKey: UUID().uuidString)
      activity = try Activity.request(
        attributes: attributes,
        content: .init(state: state, staleDate: nil))
      result(true)
    } catch {
      NSLog("[LyricLiveActivity] request failed: \(error)")
      activity = nil
      result(false)
    }
  }

  private func endAll() {
    guard #available(iOS 16.1, *) else { return }
    let a = activity
    activity = nil
    Task {
      for act in Activity<LyricLiveActivityAttributes>.activities where act.id == a?.id {
        await act.end(nil, dismissalPolicy: .immediate)
      }
    }
  }
}

extension CGImage {
  /// 简单双线性缩放（Cover 模糊预处理用）
  func resized(toWidth width: Int, height: Int) -> CGImage? {
    guard width > 0, height > 0 else { return nil }
    let ctx = CGContext(
      data: nil, width: width, height: height, bitsPerComponent: bitsPerComponent,
      bytesPerRow: 0, space: colorSpace ?? CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    ctx?.interpolationQuality = .medium
    ctx?.draw(self, in: CGRect(x: 0, y: 0, width: width, height: height))
    return ctx?.makeImage()
  }
}
