//
//  BroadcastAudioHandler.swift
//  MD3MusicBroadcast
//
//  系统声音识曲的音频采集端（ReplayKit 广播上传扩展）。
//
//  用户在系统控制中心长按「屏幕录制」选择 MD3Music 并开始广播后，系统把
//  其他 app 的混音输出（.audioApp）以 CMSampleBuffer 送进本扩展。这里不做
//  任何识别，只把音频混音成 Int16 单声道 PCM（采样率跟随输入），双缓冲
//  写入 App Group 容器（每 10s 翻一次缓冲），宿主 App 的识曲循环每 8s
//  读尾部窗口走现有指纹识别管线 —— 两边零直接通信，协议就是文件。
//
//  协议（落在 App Group 容器 sysrecog/ 子目录）：
//  - seg_0.pcm / seg_1.pcm   双缓冲原始 PCM（Int16 LE mono，采样率见 meta）
//  - seg_meta.json           {"writing":0|1,"bytes":N,"sampleRate":48000,
//                             "ts":<毫秒>,"stopped":false}
//
//  写序约定：先写数据文件再更新 meta（bytes 单调递增，写完数据才 +N），
//  Dart 读到多少算多少，天然无撕裂读；freshness 由 ts（最后一次追加时间）
//  判断，广播暂停/停止后 ts 停更 → Dart 侧 15s 内视为新鲜。
//
//  App Group 免签动态解析：与 WidgetSync 同款 —— 免费签名工具会把 group
//  重签成 group.<bundle>.<TEAM_ID>，这里同样从自身签名 entitlements 读
//  application-groups 并验证容器可访问，与宿主 App 解析出同一个组。
//

import ReplayKit

class BroadcastAudioHandler: RPBroadcastSampleHandler {

  // MARK: - 状态

  private let queue = DispatchQueue(label: "com.md3music.broadcast.audio", qos: .userInitiated)
  private var groupDir: URL?
  private var writingIndex = 0
  private var writtenBytes = 0
  private var sampleRate: Int = 0
  private var lastMetaWriteUptime: TimeInterval = 0
  private var fileHandles: [FileHandle?] = [nil, nil]

  /// 每个缓冲的容量（字节）：按实际采样率在首帧时确定（10s × 2字节/样本）
  private var bufferCapBytes: Int { (sampleRate > 0 ? sampleRate : 48000) * 2 * 10 }

  private var queue2sBeatUptime: TimeInterval = 0

  private var segFileUrl: URL {
    groupDir!.appendingPathComponent("seg_\(writingIndex).pcm")
  }
  private var metaUrl: URL {
    groupDir!.appendingPathComponent("seg_meta.json")
  }

  // MARK: - 生命周期

  override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
    queue.async { [weak self] in
      guard let self else { return }
      self.groupDir = Self.resolveAppGroupContainer()?.appendingPathComponent("sysrecog")
      guard let dir = self.groupDir else { return }
      NSLog(
        "[MD3Broadcast] broadcast started, group=%@ dir=%@",
        Self.resolvedGroupId ?? "?", dir.path)
      try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      self.writingIndex = 0
      self.writtenBytes = 0
      self.sampleRate = 0
      self.fileHandles = [nil, nil]
      // 开播清场：两个缓冲都截断，meta 归零（writing=0, bytes=0）
      for i in 0...1 {
        FileManager.default.createFile(
          atPath: dir.appendingPathComponent("seg_\(i).pcm").path, contents: nil)
      }
      self.writeMeta(stopped: false)
    }
  }

  override func broadcastFinished() {
    queue.async { [weak self] in
      guard let self else { return }
      NSLog("[MD3Broadcast] broadcast finished")
      self.writeMeta(stopped: true)
      for i in 0...1 {
        try? self.fileHandles[i]?.close()
        self.fileHandles[i] = nil
      }
    }
  }

  // MARK: - 音频样本

  override func processSampleBuffer(
    _ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType
  ) {
    guard sampleBufferType == .audioApp else { return }
    guard
      let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
      let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)
    else { return }
    let asbd = asbdPtr.pointee
    guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
    let length = CMBlockBufferGetDataLength(block)
    guard length > 0 else { return }
    var data = Data(count: length)
    let copied = data.withUnsafeMutableBytes { raw -> Bool in
      guard let base = raw.baseAddress else { return false }
      let status = CMBlockBufferCopyDataBytes(
        block, atOffset: 0, dataLength: length, destination: base)
      return status == kCMBlockBufferNoErr
    }
    guard copied else { return }

    let rate = Int(asbd.mSampleRate)
    let channels = Int(asbd.mChannelsPerFrame)
    let floats = decodeToMonoFloat(
      asbd: asbd, channels: channels, data: data)
    guard let floats, !floats.isEmpty else { return }

    // Float [-1,1] → Int16 LE 字节
    var pcm = Data(count: floats.count * 2)
    pcm.withUnsafeMutableBytes { raw in
      let out = raw.bindMemory(to: Int16.self)
      for (i, f) in floats.enumerated() {
        let clamped = max(-1.0, min(1.0, f))
        out[i] = Int16(clamped * 32767.0)
      }
    }

    queue.async { [weak self] in
      guard let self else { return }
      guard self.groupDir != nil else { return }
      if self.sampleRate == 0 {
        self.sampleRate = rate
        NSLog(
          "[MD3Broadcast] first audio sample: rate=%ld ch=%ld bits=%ld float=%ld nonInterleaved=%ld",
          rate, channels, Int(asbd.mBitsPerChannel),
          (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0 ? 1 : 0,
          (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0 ? 1 : 0)
      }
      self.append(pcm)
    }
  }

  /// 解码成单声道 Float（多声道取平均）。支持 ReplayKit 实际产出的三种
  /// 排布：Float32 非交织 / Float32 交织 / Int16 交织。
  private func decodeToMonoFloat(
    asbd: AudioStreamBasicDescription, channels: Int, data: Data
  ) -> [Float]? {
    let ch = max(1, channels)
    let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
    let isNonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
    return data.withUnsafeBytes { raw -> [Float]? in
      guard let base = raw.baseAddress else { return nil }
      let byteCount = data.count
      if isFloat, isNonInterleaved {
        // 非交织：[ch0 全部帧][ch1 全部帧]...，每通道 4 字节/样本
        let frames = byteCount / (4 * ch)
        guard frames > 0 else { return nil }
        let planes = base.bindMemory(to: Float.self, capacity: byteCount / 4)
        var out = [Float](repeating: 0, count: frames)
        for f in 0..<frames {
          var sum: Float = 0
          for c in 0..<ch {
            sum += planes[c * frames + f]
          }
          out[f] = sum / Float(ch)
        }
        return out
      }
      if isFloat {
        // 交织 Float32
        let frames = byteCount / (4 * ch)
        guard frames > 0 else { return nil }
        let values = base.bindMemory(to: Float.self, capacity: byteCount / 4)
        var out = [Float](repeating: 0, count: frames)
        for f in 0..<frames {
          var sum: Float = 0
          for c in 0..<ch {
            sum += values[f * ch + c]
          }
          out[f] = sum / Float(ch)
        }
        return out
      }
      if asbd.mBitsPerChannel == 16 {
        // 交织 Int16
        let frames = byteCount / (2 * ch)
        guard frames > 0 else { return nil }
        let values = base.bindMemory(to: Int16.self, capacity: byteCount / 2)
        var out = [Float](repeating: 0, count: frames)
        for f in 0..<frames {
          var sum: Float = 0
          for c in 0..<ch {
            sum += Float(values[f * ch + c]) / 32768.0
          }
          out[f] = sum / Float(ch)
        }
        return out
      }
      return nil
    }
  }

  // MARK: - 文件写入

  private func append(_ pcm: Data) {
    let handle: FileHandle
    if let h = fileHandles[writingIndex] {
      handle = h
    } else {
      guard FileManager.default.fileExists(atPath: segFileUrl.path)
          || FileManager.default.createFile(atPath: segFileUrl.path, contents: nil)
      else { return }
      guard let h = try? FileHandle(forWritingTo: segFileUrl) else { return }
      try? h.seekToEnd()
      fileHandles[writingIndex] = h
      handle = h
    }
    try? handle.write(pcm)
    writtenBytes += pcm.count

    let now = ProcessInfo.processInfo.systemUptime
    if now - queue2sBeatUptime >= 2.0 {
      // 诊断心跳：确认扩展在持续收到系统音频并落盘
      queue2sBeatUptime = now
      NSLog(
        "[MD3Broadcast] seg=%ld bytes=%ld rate=%ld",
        writingIndex, writtenBytes, sampleRate)
    }
    if writtenBytes >= bufferCapBytes {
      // 满 10s 翻缓冲：先把当前缓冲的终态写进 meta，再切到另一个并截断
      writeMeta(stopped: false)
      writingIndex = (writingIndex + 1) % 2
      writtenBytes = 0
      try? fileHandles[writingIndex]?.close()
      fileHandles[writingIndex] = nil
      FileManager.default.createFile(atPath: segFileUrl.path, contents: nil)
      writeMeta(stopped: false)
    } else if now - lastMetaWriteUptime >= 0.5 {
      // 节流：每 0.5s 刷一次 meta（bytes 单调递增，Dart 读到即完整数据）
      writeMeta(stopped: false)
    } else {
      _ = now
    }
  }

  private func writeMeta(stopped: Bool) {
    guard let dir = groupDir else { return }
    var meta: [String: Any] = [
      "writing": writingIndex,
      "bytes": writtenBytes,
      "sampleRate": sampleRate,
      "ts": Int64(Date().timeIntervalSince1970 * 1000),
      "stopped": stopped,
    ]
    // 写入扩展侧解析出的组 id：宿主比对可发现免签两侧没分到同一个组
    if let g = Self.resolvedGroupId {
      meta["group"] = g
    }
    guard let json = try? JSONSerialization.data(withJSONObject: meta) else { return }
    // 原子替换，Dart 读到的是完整 JSON
    try? json.write(to: metaUrl, options: .atomic)
    lastMetaWriteUptime = ProcessInfo.processInfo.systemUptime
  }

  // MARK: - App Group 免签动态解析（与 Runner/WidgetSync.swift 同款）

  static let declaredAppGroupId = "group.com.md3music.md3music"

  /// 本次实际解析出的 App Group id（写入 meta 供宿主比对）
  static var resolvedGroupId: String?

  static func resolveAppGroupContainer() -> URL? {
    var candidates = signedAppGroups() ?? []
    if !candidates.contains(declaredAppGroupId) { candidates.append(declaredAppGroupId) }
    for g in candidates {
      if let url = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: g)
      {
        resolvedGroupId = g
        NSLog("[MD3Broadcast] resolved app group: %@", g)
        return url
      }
    }
    NSLog("[MD3Broadcast] no usable app group container")
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
      @convention(c) (OpaquePointer?, CFString, UnsafeMutableRawPointer?) -> CFTypeRef?
    guard let task = unsafeBitCast(createSym, to: CreateFn.self)(nil) else { return nil }
    guard
      let value = unsafeBitCast(copySym, to: CopyFn.self)(
        task, "com.apple.security.application-groups" as CFString, nil)
    else { return nil }
    let list = (value as? [Any])?.compactMap { $0 as? String }
    return (list?.isEmpty ?? true) ? nil : list
  }
}
