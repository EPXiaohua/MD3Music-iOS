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

  /// 原始字节探针：把收到的 block buffer 原样累积，≥512KB 覆盖写
  /// raw_probe.bin（诊断用——WAV 实测为密码学级伪随机（相邻相关≈0、字节
  /// 分布均匀），需对比「未解码原始字节」区分格式矛盾 vs 源头随机）
  private var rawProbe = Data()
  /// 首帧确定的 ASBD 完整描述（写进 meta 供 Dart 打印）
  private var fmtDescription: String?

  /// 诊断状态：解码失败计数/最近失败原因/样本类型统计（02:13 日志发现
  /// 广播启动了但 append 从未执行——解码全失败时必须把原因带出扩展）
  private var failCount = 0
  private var lastFailReason = ""
  private var lastFailMetaUptime: TimeInterval = 0
  private var appSampleCount = 0
  private var micSampleCount = 0
  /// 当前生效样本源："app" / "mic"（mic 仅在从未收到 .audioApp 时降级启用）
  private var activeSrc = ""

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
      self.fmtDescription = nil
      self.rawProbe.removeAll(keepingCapacity: false)
      self.failCount = 0
      self.lastFailReason = ""
      self.appSampleCount = 0
      self.micSampleCount = 0
      self.activeSrc = ""
      try? FileManager.default.removeItem(at: dir.appendingPathComponent("raw_probe.bin"))
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
    // .audioApp = 其他 app 混音输出（首选）；.audioMic = 麦克风。部分设备/
    // 版本可能只送 .audioMic——从未收到 .audioApp 时降级用 mic（meta.src 可见）
    guard sampleBufferType == .audioApp || sampleBufferType == .audioMic else {
      return
    }
    let isApp = sampleBufferType == .audioApp
    guard
      let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
      let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)
    else {
      recordFailure("no format desc")
      return
    }
    let asbd = asbdPtr.pointee

    // ASBD 描述在解码前确定（解码失败也要把格式信息带出来）
    if fmtDescription == nil {
      let flags = asbd.mFormatFlags
      fmtDescription =
        "rate=\(Int(asbd.mSampleRate)) ch=\(asbd.mChannelsPerFrame) "
        + "bits=\(asbd.mBitsPerChannel) bytesPerFrame=\(asbd.mBytesPerFrame) "
        + "bytesPerPacket=\(asbd.mBytesPerPacket) framesPerPacket=\(asbd.mFramesPerPacket) "
        + "float=\((flags & kAudioFormatFlagIsFloat) != 0 ? 1 : 0) "
        + "signedInt=\((flags & kAudioFormatFlagIsSignedInteger) != 0 ? 1 : 0) "
        + "bigEndian=\((flags & kAudioFormatFlagIsBigEndian) != 0 ? 1 : 0) "
        + "nonInterleaved=\((flags & kAudioFormatFlagIsNonInterleaved) != 0 ? 1 : 0)"
    }

    // 原始字节探针：在样本有效期内同步拷贝（与解码路径独立，无论解码
    // 成败都落 raw_probe.bin 供宿主导出对比）
    let raw: Data? = {
      guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }
      let length = CMBlockBufferGetDataLength(block)
      guard length > 0 else { return nil }
      var data = Data(count: length)
      let ok = data.withUnsafeMutableBytes { raw -> Bool in
        guard let base = raw.baseAddress else { return false }
        return CMBlockBufferCopyDataBytes(
          block, atOffset: 0, dataLength: length, destination: base)
          == kCMBlockBufferNoErr
      }
      return ok ? data : nil
    }()

    let decoded = decodeSampleToMonoFloat(sampleBuffer, asbd: asbd)
    guard let floats = decoded.floats, !floats.isEmpty else {
      recordFailure(decoded.fail ?? "unknown")
      return
    }

    let rate = Int(asbd.mSampleRate)
    let channels = Int(asbd.mChannelsPerFrame)

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
      if isApp { self.appSampleCount += 1 } else { self.micSampleCount += 1 }
      // mic 样本只在从未收到 .audioApp 时接受（降级），src 标注当前源
      guard isApp || self.appSampleCount == 0 else { return }
      self.activeSrc = isApp ? "app" : "mic"
      if self.sampleRate == 0 {
        self.sampleRate = rate
        NSLog(
          "[MD3Broadcast] first audio sample (src=%@): %@",
          self.activeSrc as NSString, (self.fmtDescription ?? "?") as NSString)
      }
      if let raw {
        self.rawProbe.append(raw)
        self.flushRawProbeIfNeeded()
      }
      self.append(pcm)
    }
  }

  /// 解码失败留痕：计数 + 节流刷 meta（Dart 读到 fmt/err/src 打印定位）。
  /// 失败也刷新 ts——Dart 的 15s 新鲜窗口会把「有广播但无数据」识别为
  /// "meta present but empty"（回退麦克风）而非误判广播停止。
  private func recordFailure(_ reason: String, raw: Data? = nil) {
    queue.async { [weak self] in
      guard let self, self.groupDir != nil else { return }
      self.failCount += 1
      self.lastFailReason = reason
      if let raw {
        self.rawProbe.append(raw)
        self.flushRawProbeIfNeeded()
      }
      if self.failCount <= 3 {
        NSLog(
          "[MD3Broadcast] decode fail #%ld: %@",
          self.failCount, reason as NSString)
      }
      let now = ProcessInfo.processInfo.systemUptime
      if now - self.lastFailMetaUptime >= 1.0 {
        self.lastFailMetaUptime = now
        self.writeMeta(stopped: false)
      }
    }
  }

  private func flushRawProbeIfNeeded() {
    if rawProbe.count >= 512 * 1024 {
      try? rawProbe.write(
        to: groupDir!.appendingPathComponent("raw_probe.bin"), options: .atomic)
      rawProbe.removeAll(keepingCapacity: true)
    }
  }

  /// 官方姿势解码：经 CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer
  /// 拿 AudioBufferList，逐 buffer 按系统给出的 mData/mDataByteSize/
  /// mNumberChannels 读取，**零内存布局假设**。
  ///
  /// 此前实现直接 raw-copy 整个 block buffer，对非交织按「[ch0 全部帧]
  /// [ch1 全部帧] 连续拼接」猜测索引——真机实测解出纯噪音（用户听
  /// recog_segment.wav 确认），即该布局假设不成立。
  ///
  /// 规则：buffer 内按帧跨其声道数平均（交织）；多 buffer（非交织，每块
  /// 单声道）再跨块按帧平均；输出 Int16 mono。
  /// 失败返回 (nil, 原因串)——原因随 meta.err 带出扩展。
  private func decodeSampleToMonoFloat(
    _ sampleBuffer: CMSampleBuffer, asbd: AudioStreamBasicDescription
  ) -> (floats: [Float]?, fail: String?) {
    let ch = max(1, Int(asbd.mChannelsPerFrame))
    let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
    let bytesPerSample = Int(asbd.mBitsPerChannel) / 8
    guard bytesPerSample == 4 || bytesPerSample == 2 else {
      return (
        nil, "unsupported bits=\(asbd.mBitsPerChannel) float=\(isFloat ? 1 : 0)"
      )
    }

    // AudioBufferList 是 C 变长结构：静态含 1 个 buffer 槽，按声道数补足。
    // mBuffers[0] 偏移 = AudioBufferList.size - AudioBuffer.size（C ABI 固定
    // 布局，arm64/x86_64 均为 8）。
    let listSize = MemoryLayout<AudioBufferList>.size
      + (ch - 1) * MemoryLayout<AudioBuffer>.size
    let listPtr = UnsafeMutableRawPointer.allocate(
      byteCount: listSize, alignment: MemoryLayout<AudioBuffer>.alignment)
    defer { listPtr.deallocate() }
    listPtr.initializeMemory(as: UInt8.self, repeating: 0, count: listSize)
    let ablPtr = listPtr.assumingMemoryBound(to: AudioBufferList.self)

    var neededSize = 0
    var blockBuffer: CMBlockBuffer?
    let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
      sampleBuffer,
      bufferListSizeNeededOut: &neededSize,
      bufferListOut: ablPtr,
      bufferListSize: listSize,
      blockBufferAllocator: kCFAllocatorDefault,
      blockBufferMemoryAllocator: kCFAllocatorDefault,
      flags: 0,
      blockBufferOut: &blockBuffer)
    guard status == noErr else {
      return (nil, "abl status=\(status) needed=\(neededSize)")
    }
    guard blockBuffer != nil else { return (nil, "abl no block buffer") }

    let bufCount = Int(ablPtr.pointee.mNumberBuffers)
    guard bufCount > 0 else { return (nil, "bufCount=0") }
    let firstBufOffset =
      MemoryLayout<AudioBufferList>.size - MemoryLayout<AudioBuffer>.size

    // 逐 buffer 解成 [Float]（buffer 内按帧跨声道平均），记录最小帧数
    var arrays: [[Float]] = []
    var minFrames = Int.max
    for i in 0..<bufCount {
      let bufRaw = listPtr.advanced(
        by: firstBufOffset + i * MemoryLayout<AudioBuffer>.size)
      let buf = bufRaw.bindMemory(to: AudioBuffer.self, capacity: 1).pointee
      let bufCh = max(1, Int(buf.mNumberChannels))
      let bytes = Int(buf.mDataByteSize)
      guard let mData = buf.mData, bytes > 0 else {
        return (nil, "buf\(i) mData=nil size=\(bytes)")
      }
      let frames = bytes / (bytesPerSample * bufCh)
      guard frames > 0 else {
        return (nil, "buf\(i) frames=0 size=\(bytes) ch=\(bufCh)")
      }
      var out = [Float](repeating: 0, count: frames)
      if isFloat, bytesPerSample == 4 {
        let v = mData.bindMemory(to: Float.self, capacity: bytes / 4)
        for f in 0..<frames {
          var s: Float = 0
          for c in 0..<bufCh { s += v[f * bufCh + c] }
          out[f] = s / Float(bufCh)
        }
      } else if bytesPerSample == 2 {
        let v = mData.bindMemory(to: Int16.self, capacity: bytes / 2)
        for f in 0..<frames {
          var s: Float = 0
          for c in 0..<bufCh { s += Float(v[f * bufCh + c]) / 32768.0 }
          out[f] = s / Float(bufCh)
        }
      } else {
        return (
          nil, "buf\(i) fmt mismatch float=\(isFloat ? 1 : 0) bits=\(asbd.mBitsPerChannel)"
        )
      }
      arrays.append(out)
      minFrames = min(minFrames, frames)
    }
    guard minFrames > 0, minFrames != .max else { return (nil, "minFrames=0") }

    // 跨 buffer（非交织多块）按帧平均 → 单声道
    if arrays.count == 1 { return (arrays[0], nil) }
    var mono = [Float](repeating: 0, count: minFrames)
    for f in 0..<minFrames {
      var s: Float = 0
      for a in arrays { s += a[f] }
      mono[f] = s / Float(arrays.count)
    }
    return (mono, nil)
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
    // 首帧确定的 ASBD 完整描述：Dart 打印，检验格式声明与实际数据是否矛盾
    if let fmt = fmtDescription {
      meta["fmt"] = fmt
    }
    // 解码失败诊断：失败原因 + 计数（Dart 变化时打印）
    if failCount > 0 {
      meta["err"] = lastFailReason
      meta["errs"] = failCount
    }
    // 当前样本源（app=其他 app 混音 / mic=降级麦克风样本）
    if !activeSrc.isEmpty {
      meta["src"] = activeSrc
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
