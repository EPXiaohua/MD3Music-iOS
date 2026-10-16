//
//  AutomixAnalysis.swift
//  Runner
//
//  AutoMix 分析用的 PCM 解码器：把音源**曲首**若干秒解码为单声道 Int16
//  小端 PCM，交给 Dart 侧做 BPM / 拍点 / 响度分析（DSP 放 Dart 是为了可单测）。
//  行为与 Android AutomixAnalysisPlugin.kt（MediaCodec）逐项对齐：
//  - channel: com.md3music.md3music/automix_analysis
//  - decodeHead(uri: String, windowMs: Int)
//      → {"sampleRate": Int, "pcm": Uint8(小端 Int16 单声道), "decodedMs": Int}
//  - 只解曲首 windowMs（默认 25s）；总预算 10s，超时/失败返回 DECODE_FAILED，
//    Dart 侧记入 failedKeys 本次会话不再重试。
//
//  Android 端由 AutomixAnalysisPlugin.kt 注册同名 channel；iOS 在此补齐。
//

import AVFoundation
import Flutter

final class AutomixAnalysisDecoder: NSObject {
  static let shared = AutomixAnalysisDecoder()

  static let channelName = "com.md3music.md3music/automix_analysis"
  static let defaultWindowMs = 25000
  /// 解码总预算（与 Android DECODE_TIMEOUT_MS 一致）
  static let decodeTimeoutSeconds = 10.0

  /// 串行队列：与 Android 的单线程 executor 一致，同一时间只解一首
  private let queue = DispatchQueue(label: "com.md3music.automix.analysis", qos: .utility)

  private override init() { super.init() }

  func attach(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: Self.channelName, binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "decodeHead" else {
      result(FlutterMethodNotImplemented)
      return
    }
    guard
      let args = call.arguments as? [String: Any],
      let uri = args["uri"] as? String, !uri.isEmpty
    else {
      result(FlutterError(code: "BAD_ARGS", message: "uri is required", details: nil))
      return
    }
    let windowMs = (args["windowMs"] as? Int) ?? Self.defaultWindowMs
    queue.async { [weak self] in
      guard let self else { return }
      let out = self.decodeHead(uri: uri, windowMs: windowMs)
      DispatchQueue.main.async {
        if let out {
          result(out)
        } else {
          result(
            FlutterError(code: "DECODE_FAILED", message: "decode failed: \(uri)", details: nil))
        }
      }
    }
  }

  /// 全同步解码：AVAssetReader 输出 16bit 有符号整型单声道 PCM（转换器自动
  /// 立体声下混，采样率保持源值），累计到 windowMs 对应帧数即停。同步属性
  /// 访问与读取循环的阻塞风险与 Android setDataSource/MediaCodec 同档，
  /// 由 deadline 兜底；失败 Dart 侧本次会话不重试。
  private func decodeHead(uri: String, windowMs: Int) -> [String: Any]? {
    guard let url = URL(string: uri), windowMs > 0 else { return nil }
    let asset = AVURLAsset(url: url)
    // 同步轨道访问：iOS 16+ 标记 deprecated 但仍可用；分析在 utility 队列
    // 执行，不值得为 async API 引入并发复杂度。
    guard let track = asset.tracks(withMediaType: .audio).first else { return nil }
    let reader: AVAssetReader
    do {
      reader = try AVAssetReader(asset: asset)
    } catch {
      return nil
    }
    // 只要求 16bit 整型输出：float/高比特深源由转换器转换（比 Android 对
    // 非 16bit 输出直接放弃更宽容，不影响 DSP 正确性）
    let output = AVAssetReaderTrackOutput(
      track: track,
      outputSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
        AVNumberOfChannelsKey: 1,
      ])
    output.alwaysCopiesSampleData = false
    guard reader.canAdd(output) else { return nil }
    reader.add(output)
    guard reader.startReading() else { return nil }

    let deadline = Date().addingTimeInterval(Self.decodeTimeoutSeconds)
    var sampleRate = 0
    var targetFrames = 0
    var produced = 0
    var pcm = Data()

    while reader.status == .reading {
      if Date() > deadline { break }
      if targetFrames > 0, produced >= targetFrames { break }
      guard let sb = output.copyNextSampleBuffer() else { break }
      // 输出采样率从首个 buffer 的格式描述读取（未重采样 = 源采样率）
      if sampleRate == 0 {
        guard
          let desc = CMSampleBufferGetFormatDescription(sb),
          let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee,
          asbd.mSampleRate > 0
        else { continue }
        sampleRate = Int(asbd.mSampleRate)
        targetFrames = max(1, sampleRate * windowMs / 1000)
      }
      guard let block = CMSampleBufferGetDataBuffer(sb) else { continue }
      let frames = min(CMBlockBufferGetDataLength(block) / 2, targetFrames - produced)
      guard frames > 0 else { continue }
      var totalLength = 0
      var pointer: UnsafeMutablePointer<Int8>?
      guard
        CMBlockBufferGetDataPointer(
          block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &totalLength,
          dataPointerOut: &pointer) == kCMBlockBufferNoErr,
        let p = pointer
      else { continue }
      // 单声道 16bit 交错 = 连续 Int16 小端，直接按字节追加
      // （Dart 侧 Int16List.view 零拷贝，与 Android 小端字节流同构）
      pcm.append(p.assumingMemoryBound(to: UInt8.self), count: frames * 2)
      produced += frames
    }
    reader.cancelReading()

    guard sampleRate > 0, produced > 0 else { return nil }
    return [
      "sampleRate": sampleRate,
      "pcm": pcm,
      "decodedMs": produced * 1000 / sampleRate,
    ]
  }
}
