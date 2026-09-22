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
    tapStorageOut.pointee = clientInfo
}

let eqTapFinalize: MTAudioProcessingTapFinalizeCallback = { tap in
    // Optional(...) 包装兼容 SDK optional / non-optional 两种返回 audit
    guard let storage = Optional(MTAudioProcessingTapGetStorage(tap)) else { return }
    Unmanaged<EqTapState>.fromOpaque(storage).release()
}

let eqTapPrepare: MTAudioProcessingTapPrepareCallback = { tap, _, processingFormat in
    guard let storage = Optional(MTAudioProcessingTapGetStorage(tap)) else { return }
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
    guard let storage = Optional(MTAudioProcessingTapGetStorage(tap)) else { return }
    let state = Unmanaged<EqTapState>.fromOpaque(storage).takeUnretainedValue()
    for ch in state.channels.indices {
        for b in state.channels[ch].indices {
            state.channels[ch][b].reset()
        }
    }
}

let eqTapProcess: MTAudioProcessingTapProcessCallback = { tap, numberFrames, _, bufferListInOut, numberFramesOut, flagsOut in
    // 拉源 PCM（PostEffects 标志下为解码后 float32，多数场景非交织）。
    // Xcode 26 SDK 签名变更：process 回调删除了 bufferListOut（输出 = 原地
    // 处理 bufferListInOut），第 5/6 参为 numberFramesOut/flagsOut。
    // numberFramesOut 必须回写实际输出帧数——否则渲染器读到未初始化值，
    // 把本次输出当 0 帧填充 → 整条播放链静音（与 EQ 开关无关）。
    var framesOut: CMItemCount = numberFrames
    var sourceFlags: MTAudioProcessingTapFlags = 0
    let status = MTAudioProcessingTapGetSourceAudio(tap, numberFrames, bufferListInOut,
                                                    &sourceFlags, nil, &framesOut)
    guard status == noErr else { return }
    numberFramesOut.pointee = framesOut
    flagsOut.pointee = sourceFlags
    let frames = Int(framesOut)

    guard let storage = Optional(MTAudioProcessingTapGetStorage(tap)) else { return }
    let state = Unmanaged<EqTapState>.fromOpaque(storage).takeUnretainedValue()

    // 流不连续（seek/换源）时重置滤波器状态，避免残留旧音频的滤波记忆
    if sourceFlags & kMTAudioProcessingTapFlag_StartOfStream != 0 {
        for c in state.channels.indices {
            for b in state.channels[c].indices {
                state.channels[c][b].reset()
            }
        }
    }

    // 有增益变更/采样率变化时重算系数（gain==0 的段直接跳过 = 完美直通）
    state.syncCoeffsIfNeeded()

    // 频谱采样：取 EQ 处理前的原始信号。必须放在 activeBands guard 之前——
    // EQ 关闭时 activeBands 为空，若在 guard 之后这里永远执行不到，
    // Dart 端 1.5s 收不到 FFT 会误降级模拟模式（"设备不支持频谱"toast 根因）
    guard state.float32, state.channelCount > 0 else { return }
    guard frames > 0 else { return }

    let buffers = UnsafeMutableAudioBufferListPointer(bufferListInOut)
    AudioEqualizer.spectrumFeed(buffers)

    // EQ 关闭（无活动频段）时跳过滤波处理，tap 仅承担频谱采样职责
    guard !state.activeBands.isEmpty else { return }
    if state.nonInterleaved {
        for (c, buf) in buffers.enumerated() {
            guard c < state.channelCount, c < state.channels.count,
                  let data = buf.mData else { continue }
            // mDataByteSize 是 UInt32，参与帧数运算需转 Int
            let sampleCount = Int(buf.mDataByteSize) / 4
            let samples = data.bindMemory(to: Float.self, capacity: sampleCount)
            var filters = state.channels[c]
            for i in 0..<min(frames, sampleCount) {
                var s = Double(samples[i])
                for bi in state.activeBands {
                    s = filters[bi].apply(s)
                }
                // 限幅防削波：多频段增益叠加可能使样本超出 ±1.0，
                // float32 直接溢出会 wrap 成爆音（Android 系统 Equalizer
                // 在效果框架内部有限幅，tap 需自行保护）
                samples[i] = Float(max(-1.0, min(1.0, s)))
            }
            state.channels[c] = filters
        }
    } else {
        // 交织 float32：帧步进 mNumberChannels
        for buf in buffers {
            guard let data = buf.mData else { continue }
            let ch = Int(buf.mNumberChannels)
            guard ch > 0, state.channelCount > 0 else { continue }
            let total = Int(buf.mDataByteSize) / 4
            let samples = data.bindMemory(to: Float.self, capacity: total)
            for c in 0..<min(ch, state.channelCount) {
                var filters = state.channels[c]
                for i in stride(from: c, to: total, by: ch) {
                    var s = Double(samples[i])
                    for bi in state.activeBands {
                        s = filters[bi].apply(s)
                    }
                    // 同上：限幅防削波
                    samples[i] = Float(max(-1.0, min(1.0, s)))
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

    /// 5 段中心频率（Hz），与 Android 系统 Equalizer 一致
    /// （android.media.audiofx.Equalizer 设备典型值：60/230/910/3600/14000）
    static let bandFreqs: [Double] = [60, 230, 910, 3600, 14000]
    static let bandCount = 5
    /// 增益范围 mB（与 Android 侧同单位：毫贝，同范围 ±1500 mB = ±15 dB）
    static let minLevel = -1500
    static let maxLevel = 1500

    /// 保护 enabled/gains/version；process 回调在音频线程也会短暂持锁
    var lock = os_unfair_lock()
    private(set) var enabled = false
    private(set) var gains: [Double] = Array(repeating: 0.0, count: bandCount) // dB
    /// 参数版本号：任何变更 +1，tap 状态据此重算系数
    private(set) var version = 0

    private var channel: FlutterMethodChannel?
    private var observer: NSObjectProtocol?
    private var prepared = false

    // MARK: - 频谱捕获（音乐频谱可视化，协议对齐 Android SpectrumPlugin）

    /// 频谱通道：解码后 PCM → 1024 点 FFT → 40 段归一化幅值 → Dart "onFft"
    static let spectrumChannelName = "com.md3music.md3music/spectrum"
    static let fftSize = 1024
    static let spectrumBandCount = 40
    /// 发射节流：约 20fps（对齐 Android MIN_EMIT_INTERVAL_MS）
    static let spectrumEmitIntervalMs: UInt64 = 45

    /// 保护 FFT 工作缓冲（crossfade 时双 tap 在不同渲染线程并发 process）
    static var spectrumLock = os_unfair_lock()
    static var spectrumChannel: FlutterMethodChannel?
    static var spectrumCaptureEnabled = false
    // 以下仅在音频线程访问（spectrumFeed 持锁期间）
    static var pcmSamples = [Float](repeating: 0, count: fftSize)
    static var pcmWritePos = 0
    static var pcmFilled = 0
    static var lastEmitMs: UInt64 = 0
    static var fftReal = [Float](repeating: 0, count: fftSize)
    static var fftImag = [Float](repeating: 0, count: fftSize)
    static var fftMags = [Double](repeating: 0, count: spectrumBandCount)

    /// 注册频谱 MethodChannel（bootstrap 时调用，主线程）。
    /// 协议对齐 Android SpectrumPlugin：start/stop 由 Dart 驱动，原生主动推 onFft。
    static func setupSpectrumChannel(_ messenger: FlutterBinaryMessenger) {
        let ch = FlutterMethodChannel(name: spectrumChannelName, binaryMessenger: messenger)
        ch.setMethodCallHandler { call, result in
            switch call.method {
            case "start":
                os_unfair_lock_lock(&spectrumLock)
                pcmWritePos = 0
                pcmFilled = 0
                lastEmitMs = 0
                os_unfair_lock_unlock(&spectrumLock)
                spectrumCaptureEnabled = true
                result(true)
            case "stop":
                spectrumCaptureEnabled = false
                os_unfair_lock_lock(&spectrumLock)
                pcmFilled = 0
                os_unfair_lock_unlock(&spectrumLock)
                result(true)
            default:
                result(FlutterMethodNotImplemented)
            }
        }
        spectrumChannel = ch
    }

    /// 音频线程调用：采样左声道写入环形缓冲；攒满 1024 点且距上次发射 ≥45ms
    /// 时做 FFT，把 40 段幅值 post 到主线程推送 Dart。
    static func spectrumFeed(_ buffers: UnsafeMutableAudioBufferListPointer) {
        guard spectrumCaptureEnabled, spectrumChannel != nil else { return }
        os_unfair_lock_lock(&spectrumLock)
        defer { os_unfair_lock_unlock(&spectrumLock) }

        // 只采左声道：非交织取第一个 buffer，交织按帧步进取第一样本
        for buf in buffers {
            guard let data = buf.mData else { continue }
            let total = Int(buf.mDataByteSize) / 4
            let ch = Int(buf.mNumberChannels)
            let samples = data.bindMemory(to: Float.self, capacity: max(1, total))
            if ch > 1 {
                var i = 0
                while i < total {
                    let v = samples[i]
                    if v.isFinite { pcmPush(v) }
                    i += ch
                }
            } else {
                for i in 0..<total {
                    let v = samples[i]
                    if v.isFinite { pcmPush(v) }
                }
            }
            break
        }

        guard pcmFilled >= fftSize else { return }
        let nowMs = DispatchTime.now().uptimeNanoseconds / 1_000_000
        guard nowMs - lastEmitMs >= spectrumEmitIntervalMs else { return }
        lastEmitMs = nowMs

        let bands = computeSpectrumBandsLocked()
        pcmFilled -= fftSize
        // 实时音频线程不做 IPC：算完 post 主线程再走 MethodChannel
        DispatchQueue.main.async {
            spectrumChannel?.invokeMethod("onFft", arguments: bands)
        }
    }

    @inline(__always)
    private static func pcmPush(_ v: Float) {
        pcmSamples[pcmWritePos] = v
        pcmWritePos = (pcmWritePos + 1) % fftSize
        if pcmFilled < fftSize { pcmFilled += 1 }
    }

    /// 需持有 spectrumLock 调用：环形缓冲最近 1024 点 → FFT → 前 40 bin 归一化
    /// （跳过 DC 从 bin1 开始，与 Android computeBandsFromPcm 视觉对齐）
    private static func computeSpectrumBandsLocked() -> [Double] {
        let start = pcmWritePos
        for i in 0..<fftSize {
            fftReal[i] = pcmSamples[(start + i) % fftSize]
            fftImag[i] = 0
        }
        fftRadix2(&fftReal, &fftImag)

        let usable = min(fftSize / 2, spectrumBandCount)
        var maxMag = 1.0
        for i in 0..<usable {
            let re = Double(fftReal[i + 1]), im = Double(fftImag[i + 1])
            let mag = (re * re + im * im).squareRoot()
            fftMags[i] = mag
            if mag > maxMag { maxMag = mag }
        }
        var bands = [Double](repeating: 0, count: spectrumBandCount)
        for i in 0..<usable {
            bands[i] = min(max(fftMags[i] / maxMag, 0.0), 1.0)
        }
        return bands
    }

    /// 原地基 2 迭代 FFT（移植自 Android SpectrumPlugin.fftRadix2，长度须为 2 的幂）
    private static func fftRadix2(_ re: inout [Float], _ im: inout [Float]) {
        let n = re.count
        // 位反转
        var j = 0
        for i in 0..<(n - 1) {
            if i < j {
                re.swapAt(i, j)
                im.swapAt(i, j)
            }
            var m = n >> 1
            while j >= m { j -= m; m >>= 1 }
            j += m
        }
        // 蝶形运算
        var len = 2
        while len <= n {
            let ang = -2.0 * Double.pi / Double(len)
            let wRe = Float(cos(ang)), wIm = Float(sin(ang))
            var i = 0
            while i < n {
                var curRe: Float = 1.0, curIm: Float = 0.0
                let half = len / 2
                for k in 0..<half {
                    let uRe = re[i + k], uIm = im[i + k]
                    let vRe = re[i + k + half] * curRe - im[i + k + half] * curIm
                    let vIm = re[i + k + half] * curIm + im[i + k + half] * curRe
                    re[i + k] = uRe + vRe
                    im[i + k] = uIm + vIm
                    re[i + k + half] = uRe - vRe
                    im[i + k + half] = uIm - vIm
                    let nRe = curRe * wRe - curIm * wIm
                    curIm = curRe * wIm + curIm * wRe
                    curRe = nRe
                }
                i += len
            }
            len <<= 1
        }
    }

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

        // 频谱可视化通道（与 Dart SpectrumService / Android SpectrumPlugin 同名协议）
        AudioEqualizer.setupSpectrumChannel(messenger)

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
        var callbacks = MTAudioProcessingTapCallbacks(
            version: 0,
            clientInfo: Unmanaged.passRetained(state).toOpaque(),
            `init`: eqTapInit,
            finalize: eqTapFinalize,
            prepare: eqTapPrepare,
            unprepare: eqTapUnprepare,
            process: eqTapProcess)

        var tapOut: MTAudioProcessingTap?
        // Xcode 26 SDK 将 MTAudioProcessingTapCreationWithCallbacks 更名为
        // MTAudioProcessingTapCreate（旧名在新 Swift overlay 中已移除）
        let status = MTAudioProcessingTapCreate(
            kCFAllocatorDefault, &callbacks,
            kMTAudioProcessingTapCreationFlag_PostEffects, &tapOut)
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
