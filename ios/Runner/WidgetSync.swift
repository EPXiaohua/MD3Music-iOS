//
//  WidgetSync.swift
//  Runner
//
//  iOS 桌面小组件数据同步：接收 Dart 侧 HomeWidgetService 推送的播放状态
//  （channel 与 Android 同名：com.md3music.md3music/home_widget），写入
//  App Group 共享容器，并触发 MD3Widget extension 刷新时间线。
//
//  数据协议（App Group UserDefaults key "widget_state"）：
//  {
//    "title": String, "artist": String,
//    "isPlaying": Bool, "position": Int(ms), "duration": Int(ms),
//    "updatedAt": Double(时间戳，widget 侧按墙钟推进进度),
//    "colors": { "panelBg": Int(ARGB), ... }   // 可缺省，缺省用系统语义色
//  }
//  封面：固定写入共享容器 widget_cover.png，每次切歌覆盖。
//
//  交互：widget 上的播放/暂停、下一首按钮（iOS 17 AppIntent）把命令写入
//  App Group（key "widget_command"）并打开 app；app 回前台时这里把命令
//  转发给 Dart（invokeMethod "widgetCommand"），由 Dart 执行实际播放控制。
//

import Flutter
import UIKit
import WidgetKit

final class WidgetSync {
  static let shared = WidgetSync()

  static let appGroupId = "group.com.md3music.md3music"
  private static let stateKey = "widget_state"
  private static let commandKey = "widget_command"
  private static let coverFileName = "widget_cover.png"
  /// UI 使用的颜色角色 key（与 Android MusicWidgetProvider 协议一致）
  static let colorKeys = [
    "panelBg", "primary", "onPrimary", "surfaceHigh",
    "onSurface", "onSurfaceVariant", "outlineVariant",
  ]

  private var channel: FlutterMethodChannel?
  private var themeColors: [String: Int] = [:]
  private var lastState: [String: Any] = [:]

  private init() {}

  // MARK: - App Group 自动发现
  //
  // 免费签名工具会改写 App Group 标识并重建签名 entitlements，各工具格式不同：
  // - isideload：`group.<bundle_id>.<TEAM_ID>`（整体重建）
  // - AltStore（AltSign）：原 group 标识尾部追加后缀 → `<原group>.<TEAM_ID>`，
  //   且会附加它自己的 `group.com.rileytestut.AltStore.<TEAM_ID>` 用于通信
  // 这里从签名 entitlements（SecTask 私有 API）与 embedded.mobileprovision
  // （Apple 下发的权威列表）解析候选，按「派生自本应用 group」启发式排序，
  // 并用容器实际写读探针验证——containerURL 对未授权 group 也可能返回非 nil，
  // 不能作为唯一判据；全部失败回退声明 id（正式签名场景）。

  private static var _resolvedGroupId: String?

  static var resolvedAppGroupId: String {
    if let r = _resolvedGroupId { return r }
    let resolved = findUsableAppGroup() ?? appGroupId
    _resolvedGroupId = resolved
    if resolved != appGroupId {
      NSLog("[WidgetSync] resolved App Group: \(resolved)")
    }
    return resolved
  }

  /// 从全部候选中找第一个容器真正可写的 group（候选已按优先级排好）。
  private static func findUsableAppGroup() -> String? {
    let signed = signedAppGroups() ?? []
    let profiled = profileAppGroups() ?? []
    var pool: [String] = []
    func add(_ ids: [String]) {
      for id in ids where !pool.contains(id) { pool.append(id) }
    }
    // 优先与声明 id 同源（派生自 group.com.md3music.md3music）的候选，
    // 防止误选签名工具附加的无关 group（如 AltStore 自身的通信 group）
    let ours: (String) -> Bool = {
      $0.hasPrefix(appGroupId) || $0.contains("md3music")
    }
    add(profiled.filter(ours))
    add(signed.filter(ours))
    add(profiled)
    add(signed)
    add([appGroupId])
    return pool.first(where: isUsableAppGroup)
  }

  /// 容器写读探针：写入并读回一个小文件，确认沙盒真正放行。
  private static func isUsableAppGroup(_ groupId: String) -> Bool {
    guard
      let container = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: groupId)
    else { return false }
    let probe = container.appendingPathComponent(".md3_probe")
    do {
      try Data([0x31]).write(to: probe, options: .atomic)
      let ok = (try? Data(contentsOf: probe)) == Data([0x31])
      try? FileManager.default.removeItem(at: probe)
      return ok
    } catch {
      return false
    }
  }

  /// 解析 embedded.mobileprovision（CMS 包装的 XML plist）中的
  /// Entitlements → application-groups。比签名 entitlements 更权威：
  /// 这是 Apple 按实际注册的 App Group 下发的列表。
  private static func profileAppGroups() -> [String]? {
    guard
      let url = Bundle.main.url(
        forResource: "embedded", withExtension: "mobileprovision"),
      let data = try? Data(contentsOf: url),
      let start = data.range(of: Data("<?xml".utf8)),
      let end = data.range(of: Data("</plist>".utf8), in: start.upperBound..<data.endIndex)
    else { return nil }
    let xml = data.subdata(in: start.lowerBound..<end.upperBound)
    guard
      let plist = try? PropertyListSerialization.propertyList(
        from: xml, options: [], format: nil) as? [String: Any],
      let entitlements = plist["Entitlements"] as? [String: Any]
    else { return nil }
    return entitlements["com.apple.security.application-groups"] as? [String]
  }

  /// 读自身签名 entitlements 的 com.apple.security.application-groups。
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

  private var groupDefaults: UserDefaults? {
    UserDefaults(suiteName: Self.resolvedAppGroupId)
  }

  private var groupContainer: URL? {
    FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: Self.resolvedAppGroupId)
  }

  /// 注册 home_widget channel（幂等）。由 AppDelegate.configureChannelsIfPossible 调用。
  func attach(messenger: FlutterBinaryMessenger) {
    guard channel == nil else { return }
    let ch = FlutterMethodChannel(
      name: "com.md3music.md3music/home_widget", binaryMessenger: messenger)
    ch.setMethodCallHandler { [weak self] call, result in
      self?.handle(call: call, result: result)
    }
    channel = ch
    // app 回前台：检查 widget 按钮写入的命令并转发给 Dart
    NotificationCenter.default.addObserver(
      self, selector: #selector(onSceneDidActivate),
      name: UIScene.didActivateNotification, object: nil)
  }

  private func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "updateWidget":
      guard let args = call.arguments as? [String: Any] else {
        result(nil)
        return
      }
      applyState(
        title: args["title"] as? String ?? "",
        artist: args["artist"] as? String ?? "",
        isPlaying: args["isPlaying"] as? Bool ?? false,
        positionMs: (args["position"] as? NSNumber)?.intValue ?? 0,
        durationMs: (args["duration"] as? NSNumber)?.intValue ?? 0)
      result(nil)
    case "updateMusicWidgetTheme":
      guard let colors = call.arguments as? [String: Int] else {
        result(nil)
        return
      }
      themeColors = colors
      applyState(lastState: lastState)
      result(nil)
    case "updateFmWidget":
      // 私人 FM 小组件暂无 iOS 版本，静默忽略
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// 写入播放状态并刷新小组件时间线。
  private func applyState(
    title: String, artist: String, isPlaying: Bool,
    positionMs: Int, durationMs: Int
  ) {
    var state = lastState
    state["title"] = title
    state["artist"] = artist
    state["isPlaying"] = isPlaying
    state["position"] = positionMs
    state["duration"] = durationMs
    applyState(lastState: state)
  }

  private func applyState(lastState newState: [String: Any]) {
    lastState = newState
    guard let defaults = groupDefaults else { return }
    var state = newState
    state["updatedAt"] = Date().timeIntervalSince1970
    if !themeColors.isEmpty { state["colors"] = themeColors }
    if let data = try? JSONSerialization.data(withJSONObject: state) {
      defaults.set(data, forKey: Self.stateKey)
    }
    writeCoverIfNeeded()
    if #available(iOS 14.0, *) {
      WidgetCenter.shared.reloadAllTimelines()
    }
  }

  /// 把 NowPlayingManager 缓存的当前封面写入共享容器（切歌时内容变化）。
  private func writeCoverIfNeeded() {
    guard let container = groupContainer,
      let image = NowPlayingManager.shared.lastArtworkImage
    else { return }
    let url = container.appendingPathComponent(Self.coverFileName)
    guard let data = image.jpegData(compressionQuality: 0.9) else { return }
    try? data.write(to: url, options: .atomic)
  }

  // MARK: - Widget 按钮命令（iOS 17 AppIntent 写入，app 回前台转发）

  /// 由 MD3Widget 的 AppIntent 调用：记录命令（下一步由 app 回前台转发 Dart）。
  static func writeCommand(_ action: String) {
    UserDefaults(suiteName: resolvedAppGroupId)?.set(
      action, forKey: commandKey)
  }

  @objc private func onSceneDidActivate() {
    forwardPendingCommand()
  }

  /// 把待处理命令转发给 Dart 执行（播放/暂停、下一首）。
  private func forwardPendingCommand() {
    // channel 未就绪时不能先删命令（invokeMethod 会丢）——留给下次回前台转发
    guard channel != nil, let defaults = groupDefaults,
      let action = defaults.string(forKey: Self.commandKey)
    else { return }
    defaults.removeObject(forKey: Self.commandKey)
    channel?.invokeMethod("widgetCommand", arguments: ["action": action])
  }

  // MARK: - 小组件 URL scheme（iOS 15/16 无 AppIntent 的按钮路径）

  /// 处理小组件按钮经 `md3music://widget/<action>` 打开 app 的命令。
  /// 命令落 App Group 后走与 AppIntent 相同的转发链路：channel 就绪立即
  /// 转发，否则由 scene didActivate（Flutter 引擎就绪后）补发。
  func handleWidgetURL(_ url: URL) {
    guard url.scheme == "md3music", url.host == "widget" else { return }
    let action = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard action == "play_pause" || action == "next" else { return }
    Self.writeCommand(action)
    forwardPendingCommand()
  }
}
