//
//  AudioEqualizer.swift
//  Runner
//
//  iOS 软件均衡器：AVPlayer 不支持 AVAudioUnit 效果器，但支持
//  AVAudioMix + MTAudioProcessingTap（解码后、输出前的 PCM 钩子）。
//  在 tap 的 process 回调里做 10 段 peaking biquad（RBJ cookbook），
//  AVPlayer 继续负责传输/流式/seek/缓冲，播放栈零重构。
//
//  挂载链路：just_audio fork（UriAudioSource.createPlayerItem）每次创建
//  AVPlayerItem 时发 NSNotification "JustAudioPlayerItemCreated"，
//  本类监听并对 item 附加 tap（覆盖主播放器 + crossfade 辅路 item2）。
//
//  bootstrap 由 just_audio fork 的 JustAudioPlugin.registerWithRegistrar
//  经 NSClassFromString("Runner.AudioEqualizer") 反射调用（插件编译在
//  独立 framework，无法直接 import Runner 的 Swift 类），不依赖 AppDelegate。
//

import AVFoundation
import Flutter
import MediaToolbox

// MARK: - biquad 滤波器

/// RBJ cookbook peaking biquad。gain==0 时该段不参与（恒等直通）。
struct BiquadCoeffs {
    var b0: Double = 1
    var b1: Double = 0
    var b2: Double = 0
    var a1: Double = 0
    var a2: Double = 0
}

/// 单声道单段的运行状态（Direct Form I）。
struct BiquadState {
    var coeffs = BiquadCoeffs()
    var x1: Double = 0
    var x2: Double = 0
    var y1: Double = 0
    var y2: Double = 0

    @inline(__always)
    mutating func apply(_ x: Double) -> Double {
        let y = coeffs.b0 * x + coeffs.b1 * x1 + coeffs.b2 * x2
            - coeffs.a1 * y1 - coeffs.a2 * y2
        x2 = x1
        x1 = x
        y2 = y1
        y1 = y
        return y
    }

    @inline(__always)
    mutating func reset() {
        x1 = 0; x2 = 0; y1 = 0; y2 = 0
    }
}

// MARK: - tap 回调（C 函数指针，不能捕获上下文）

let eqTapInit: MTAudioProcessingTapInitCallback = { _, clientInfo, tapStorageOut in
    tapStorageOut?.pointee = clientInfo
}

let eqTapFinalize: MTAudioProcessingTapFinalizeCallback = { tap in
    let storage = MTAudioProcessingTapGetStorage(tap)
    guard storage != nil else { return }
    Unmanaged<EqTapState>.fromOpaque(storage).release()
}

let eqTapPrepare: MTAudioProcessingTapPrepareCallback = { tap, _, processingFormat in
    let storage = MTAudioProcessingTapGetStorage(tap)
    guard storage != nil else { return }
    let state = Unmanaged<EqTapState>.fromOpaque(storage).takeUnretainedValue()
    // prepare 第三参本身就是 ASBD 指针（此前误当 CMFormatDescription 又调
    // CMAudioFormatDescriptionGetStreamBasicDescription，CI 上编译失败）
    let asbd = processingFormat.pointee
    state.sampleRate = asbd.mSampleRate
    state.channelCount = Int(asbd.mChannelsPerFrame)
    state.nonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
    state.float32 = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        && asbd.mBitsPerChannel == 32
    state.channels = Array(repeating: Array(repeating: BiquadState(), count: AudioEqualizer.bandFreqs.count),
                           count: max(1, state.channelCount))
    state.lastAppliedVersion = -1 // 强制按新采样率重算系数
}

let eqTapUnprepare: MTAudioProcessingTapUnprepareCallback = { tap in
    let storage = MTAudioProcessingTapGetStorage(tap)
    guard storage != nil else { return }
    let state = Unmanaged<EqTapState>.fromOpaque(storage).takeUnretainedValue()
    for ch in state.channels.indices {
        for b in state.channels[ch].indices {
            state.channels[ch][b].reset()
        }
    }
}

let eqTapProcess: MTAudioProcessingTapProcessCallback = { tap, numberFrames, _, bufferListInOut, _, _ in
    // 拉源 PCM（PostEffects 标志下为解码后 float32，多数场景非交织）。
    // flags/timeRange 不需要传 nil；帧数用本地变量接收，不依赖 SDK 对
    // flagsOut 参数的指针类型 audit（Xcode 26 上该处类型 audit 与文档不符，
    // 传 flags 指针会报 CMItemCount 类型不匹配）
    var framesOut: CMItemCount = numberFrames
    let status = MTAudioProcessingTapGetSourceAudio(tap, numberFrames, bufferListInOut,
                                                    nil, nil, &framesOut)
    guard status == noErr else { return }
    let frames = Int(framesOut)

    let storage = MTAudioProcessingTapGetStorage(tap)
    guard storage != nil else { return }
    let state = Unmanaged<EqTapState>.fromOpaque(storage).takeUnretainedValue()

    // 有增益变更/采样率变化时重算系数（gain==0 的段直接跳过 = 完美直通）
    state.syncCoeffsIfNeeded()

    guard state.float32, !state.activeBands.isEmpty, state.channelCount > 0 else { return }
    guard frames > 0 else { return }

    let buffers = UnsafeMutableAudioBufferListPointer(bufferListInOut)
    if state.nonInterleaved {
        for (c, buf) in buffers.enumerated() {
            guard c < state.channelCount, c < state.channels.count,
                  let data = buf.mData else { continue }
            let samples = data.bindMemory(to: Float.self, capacity: buf.mDataByteSize / 4)
            var filters = state.channels[c]
            for i in 0..<min(frames, buf.mDataByteSize / 4) {
                var s = Double(samples[i])
                for bi in state.activeBands {
                    s = filters[bi].apply(s)
                }
                samples[i] = Float(s)
            }
            state.channels[c] = filters
        }
    } else {
        // 交织 float32：帧步进 mNumberChannels
        for buf in buffers {
            guard let data = buf.mData else { continue }
            let ch = Int(buf.mNumberChannels)
            guard ch > 0, state.channelCount > 0 else { continue }
            let total = buf.mDataByteSize / 4
            let samples = data.bindMemory(to: Float.self, capacity: total)
            for c in 0..<min(ch, state.channelCount) {
                var filters = state.channels[c]
                for i in stride(from: c, to: total, by: ch) {
                    var s = Double(samples[i])
                    for bi in state.activeBands {
                        s = filters[bi].apply(s)
                    }
                    samples[i] = Float(s)
                }
                state.channels[c] = filters
            }
        }
    }
}

// MARK: - tap 状态（init/finalize 持有，process 在实时音频线程访问）

final class EqTapState {
    var sampleRate: Double = 44100
    var channelCount: Int = 0
    var nonInterleaved = true
    var float32 = false
    var channels: [[BiquadState]] = []
    var lastAppliedVersion: Int = -1
    /// 当前实际生效的频段索引（gain != 0 的段），空数组 = 全直通
    var activeBands: [Int] = []

    /// 由音频线程调用：均衡器参数脏了就重算系数（更新极少，开销可忽略）
    func syncCoeffsIfNeeded() {
        let shared = AudioEqualizer.shared
        os_unfair_lock_lock(&shared.lock)
        defer { os_unfair_lock_unlock(&shared.lock) }
        guard lastAppliedVersion != shared.version else { return }
        lastAppliedVersion = shared.version

        activeBands.removeAll()
        if shared.enabled {
            for (band, gain) in shared.gains.enumerated() where gain != 0 {
                activeBands.append(band)
            }
        }
        // 重算所有声道的系数（声道数未知时按当前数组算）
        for c in channels.indices {
            for (band, gain) in shared.gains.enumerated() where band < channels[c].count {
                channels[c][band].coeffs = Self.peakCoeffs(
                    freq: AudioEqualizer.bandFreqs[band],
                    sampleRate: sampleRate,
                    gainDb: shared.enabled ? gain : 0)
                channels[c][band].reset()
            }
        }
    }

    /// RBJ cookbook peaking EQ（Q=1.1，近似 10 段图示均衡器的带宽）
    static func peakCoeffs(freq: Double, sampleRate: Double, gainDb: Double) -> BiquadCoeffs {
        guard gainDb != 0, sampleRate > 0 else { return BiquadCoeffs() }
        let a = pow(10.0, gainDb / 40.0)
        let w0 = 2.0 * Double.pi * freq / sampleRate
        let cw = cos(w0)
        let alpha = sin(w0) / (2.0 * 1.1)
        let a0 = 1.0 + alpha / a
        return BiquadCoeffs(
            b0: (1.0 + alpha * a) / a0,
            b1: (-2.0 * cw) / a0,
            b2: (1.0 - alpha * a) / a0,
            a1: (-2.0 * cw) / a0,
            a2: (1.0 - alpha / a) / a0)
    }
}

// MARK: - 均衡器主类

@objc final class AudioEqualizer: NSObject {
    static let shared = AudioEqualizer()
    static let channelName = "com.md3music.md3music/equalizer"
    static let itemCreatedNotification = Notification.Name("JustAudioPlayerItemCreated")

    /// 10 段 ISO 倍频程中心频率（Hz）
    static let bandFreqs: [Double] = [31.25, 62.5, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    static let bandCount = 10
    /// 增益范围 mB（与 Android 侧同单位：毫贝）
    static let minLevel = -1200
    static let maxLevel = 1200

    /// 保护 enabled/gains/version；process 回调在音频线程也会短暂持锁
    var lock = os_unfair_lock()
    private(set) var enabled = false
    private(set) var gains: [Double] = Array(repeating: 0.0, count: bandCount) // dB
    /// 参数版本号：任何变更 +1，tap 状态据此重算系数
    private(set) var version = 0

    private var channel: FlutterMethodChannel?
    private var observer: NSObjectProtocol?
    private var prepared = false

    private override init() {
        super.init()
    }

    /// 由 just_audio fork 的 registerWithRegistrar 反射调用（早于任何播放）。
    @objc static func bootstrapWithBinaryMessenger(_ messenger: FlutterBinaryMessenger) {
        guard !shared.prepared else { return }
        shared.prepared = true

        let ch = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
        ch.setMethodCallHandler { call, result in
            shared.handle(call: call, result: result)
        }
        shared.channel = ch

        // 对每个新创建的 AVPlayerItem 附加 tap
        shared.observer = NotificationCenter.default.addObserver(
            forName: itemCreatedNotification, object: nil, queue: nil
        ) { note in
            guard let item = note.object as? AVPlayerItem else { return }
            shared.attach(to: item)
        }
    }

    // MARK: MethodChannel（与 Dart EqualizerService 对接，协议对齐 Android 插件）

    private func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "init":
            // 返回合成频段信息（软件 EQ，与设备硬件无关）
            result([
                "bandCount": AudioEqualizer.bandCount,
                "minLevel": AudioEqualizer.minLevel,
                "maxLevel": AudioEqualizer.maxLevel,
                "centerFreqs": AudioEqualizer.bandFreqs.map { Int($0 * 1000) }, // 毫赫兹
            ])
        case "getPresets":
            // 系统预设列表：预设全部在 Dart 侧定义（customPresets），返回空
            result([])
        case "setEnabled":
            let value = (call.arguments as? [String: Any])?["enabled"] as? Bool ?? false
            os_unfair_lock_lock(&lock)
            enabled = value
            version += 1
            os_unfair_lock_unlock(&lock)
            result(nil)
        case "setBandLevel":
            let args = call.arguments as? [String: Any]
            let band = args?["band"] as? Int ?? -1
            let levelMb = args?["level"] as? Int ?? 0
            guard band >= 0, band < AudioEqualizer.bandCount else {
                result(FlutterError(code: "invalid_band", message: "band \(band) out of range", details: nil))
                return
            }
            os_unfair_lock_lock(&lock)
            gains[band] = Double(levelMb) / 100.0 // mB → dB
            version += 1
            os_unfair_lock_unlock(&lock)
            result(nil)
        case "release":
            os_unfair_lock_lock(&lock)
            enabled = false
            gains = Array(repeating: 0.0, count: AudioEqualizer.bandCount)
            version += 1
            os_unfair_lock_unlock(&lock)
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: tap 附加

    private func attach(to item: AVPlayerItem) {
        guard item.audioMix == nil else { return }
        let asset = item.asset
        if #available(iOS 15.0, *) {
            asset.loadTracks(withMediaType: .audio) { tracks, _ in
                DispatchQueue.main.async {
                    // item 可能已被切歌释放
                    guard item.audioMix == nil,
                          let track = tracks?.first else { return }
                    self.installTap(item: item, track: track)
                }
            }
        } else {
            // 旧系统兜底：等 readyToPlay 后同步取音轨
            var token: NSKeyValueObservation?
            token = item.observe(\.status, options: [.initial]) { item, _ in
                guard item.status == .readyToPlay else { return }
                token?.invalidate()
                guard item.audioMix == nil else { return }
                self.installTap(item: item,
                                track: item.asset.tracks(withMediaType: .audio).first)
            }
        }
    }

    private func installTap(item: AVPlayerItem, track: AVAssetTrack?) {
        guard let track = track, item.audioMix == nil else { return }

        let state = EqTapState()
        // C struct 无默认构造，必须用 memberwise init（字段 init 是关键字需反引号）
        let callbacks = MTAudioProcessingTapCallbacks(
            version: 0,
            clientInfo: Unmanaged.passRetained(state).toOpaque(),
            `init`: eqTapInit,
            finalize: eqTapFinalize,
            prepare: eqTapPrepare,
            unprepare: eqTapUnprepare,
            process: eqTapProcess)

        var tapOut: MTAudioProcessingTap?
        // CF_OPTIONS 枚举常量导入 Swift 后去掉 k 前缀 → .postEffects
        let status = MTAudioProcessingTapCreationWithCallbacks(
            kCFAllocatorDefault, &callbacks,
            .postEffects, &tapOut)
        guard status == noErr, let tap = tapOut else {
            // 创建失败：释放保留的 state 防泄漏
            Unmanaged.passRetained(state).release()
            return
        }

        let params = AVMutableAudioMixInputParameters(track: track)
        params.audioTapProcessor = tap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [params]
        item.audioMix = mix
    }
}
