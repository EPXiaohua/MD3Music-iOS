// Widget 按钮命令 intent（主 app 与 MD3Widget extension 双 target 共享编译）。
//
// 关键设计（对齐 iOS 26 交互模型）：
// - intent 若只编译进 widget extension，系统只会在 extension 进程执行
//   perform——extension 无法驱动 Flutter 播放链路，表现为「按钮点了没反应」。
// - 本文件同时编进 Runner 与 MD3Widget 两个 target。播放控制类 intent
//   额外 conform AudioPlaybackIntent：系统据此把 intent 放到主 app 进程
//   执行（app 在后台时直接唤醒执行，不弹 UI——音乐小组件的标准交互）。
// - perform 只做一件事：把命令写入 App Group 并发进程内通知。app 侧
//   WidgetSync 监听通知转发 Dart；channel 未就绪时命令留在 App Group，
//   由回前台（scene didActivate）兜底转发。extension 进程 post 无监听者，
//   无副作用。

import Foundation
import AppIntents

// MARK: - App Group 桥（extension 与 app 两侧共用）

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

  /// AppIntent 与 app 两侧共用：把命令写入 App Group 待 app 消费，
  /// 并发进程内通知（app 进程中 WidgetSync 监听后立即转发 Dart）。
  static func writeCommand(_ action: String) {
    UserDefaults(suiteName: resolvedAppGroupId)?.set(
      action, forKey: "widget_command")
    NotificationCenter.default.post(
      name: .md3WidgetCommand, object: nil, userInfo: ["action": action])
  }
}

extension Notification.Name {
  /// 进程内命令通知（app 侧 WidgetSync 监听；extension 进程无监听者）。
  static let md3WidgetCommand = Notification.Name("com.md3music.widget.command")
}

// MARK: - 交互 intent（iOS 17+）

/// 播放控制类：conform AudioPlaybackIntent 让系统在主 app 进程执行
/// （iOS 17~25 后台唤醒 app 执行；iOS 26 同样适用），不弹 UI。
@available(iOS 17.0, iOSApplicationExtension 17.0, *)
struct PlayPauseIntent: AppIntent, AudioPlaybackIntent {
  static var title: LocalizedStringResource = "播放 / 暂停"

  func perform() async throws -> some IntentResult {
    WidgetSyncBridge.writeCommand("play_pause")
    return .result()
  }
}

@available(iOS 17.0, iOSApplicationExtension 17.0, *)
struct PreviousIntent: AppIntent, AudioPlaybackIntent {
  static var title: LocalizedStringResource = "上一首"

  func perform() async throws -> some IntentResult {
    WidgetSyncBridge.writeCommand("previous")
    return .result()
  }
}

@available(iOS 17.0, iOSApplicationExtension 17.0, *)
struct NextIntent: AppIntent, AudioPlaybackIntent {
  static var title: LocalizedStringResource = "下一首"

  func perform() async throws -> some IntentResult {
    WidgetSyncBridge.writeCommand("next")
    return .result()
  }
}

// MARK: 私人FM卡命令：写 App Group 待 app 消费
//（fm_open_track_N 不带参数，hash 由 Dart 按当前 FM 队列重算）

@available(iOS 17.0, iOSApplicationExtension 17.0, *)
struct FmPlayPauseIntent: AppIntent, AudioPlaybackIntent {
  static var title: LocalizedStringResource = "FM 播放 / 暂停"

  func perform() async throws -> some IntentResult {
    WidgetSyncBridge.writeCommand("fm_play_pause")
    return .result()
  }
}

@available(iOS 17.0, iOSApplicationExtension 17.0, *)
struct FmToggleFavoriteIntent: AppIntent, AudioPlaybackIntent {
  static var title: LocalizedStringResource = "FM 收藏"

  func perform() async throws -> some IntentResult {
    WidgetSyncBridge.writeCommand("fm_toggle_favorite")
    return .result()
  }
}

@available(iOS 17.0, iOSApplicationExtension 17.0, *)
struct FmSelectStationIntent: AppIntent, AudioPlaybackIntent {
  static var title: LocalizedStringResource = "FM 切换档位"

  func perform() async throws -> some IntentResult {
    WidgetSyncBridge.writeCommand("fm_select_station")
    return .result()
  }
}

@available(iOS 17.0, iOSApplicationExtension 17.0, *)
struct FmOpenTrack1Intent: AppIntent, AudioPlaybackIntent {
  static var title: LocalizedStringResource = "FM 起播预告曲 1"

  func perform() async throws -> some IntentResult {
    WidgetSyncBridge.writeCommand("fm_open_track_1")
    return .result()
  }
}

@available(iOS 17.0, iOSApplicationExtension 17.0, *)
struct FmOpenTrack2Intent: AppIntent, AudioPlaybackIntent {
  static var title: LocalizedStringResource = "FM 起播预告曲 2"

  func perform() async throws -> some IntentResult {
    WidgetSyncBridge.writeCommand("fm_open_track_2")
    return .result()
  }
}

@available(iOS 17.0, iOSApplicationExtension 17.0, *)
struct FmOpenTrack3Intent: AppIntent, AudioPlaybackIntent {
  static var title: LocalizedStringResource = "FM 起播预告曲 3"

  func perform() async throws -> some IntentResult {
    WidgetSyncBridge.writeCommand("fm_open_track_3")
    return .result()
  }
}

// MARK: 导航类按钮：需要把 app 拉到前台（打开播放器 / 登录页）。
// openAppWhenRun 供 iOS 17~25 读取；iOS 26 起弃用且在 extension 中设 true
// 会报错，系统改查 supportedModes（foreground immediate = 执行前把 app
// 拉到前台，语义与 openAppWhenRun=true 一致）。

@available(iOS 17.0, iOSApplicationExtension 17.0, *)
struct FmOpenPlayerIntent: AppIntent {
  static var title: LocalizedStringResource = "FM 打开播放器"
  static var openAppWhenRun = true

  @available(iOS 26.0, iOSApplicationExtension 26.0, *)
  static let supportedModes: IntentModes = [.foreground(.immediate)]

  func perform() async throws -> some IntentResult {
    WidgetSyncBridge.writeCommand("fm_open_player")
    return .result()
  }
}

@available(iOS 17.0, iOSApplicationExtension 17.0, *)
struct FmOpenLoginIntent: AppIntent {
  static var title: LocalizedStringResource = "FM 去登录"
  static var openAppWhenRun = true

  @available(iOS 26.0, iOSApplicationExtension 26.0, *)
  static let supportedModes: IntentModes = [.foreground(.immediate)]

  func perform() async throws -> some IntentResult {
    WidgetSyncBridge.writeCommand("fm_open_login")
    return .result()
  }
}
