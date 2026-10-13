//
//  HapticsPlugin.swift
//  Runner
//
//  iOS 震动反馈，对齐 Android 的三套震动子系统：
//  1. 交互震动：`md3music/haptics`（Dart `AppHaptics`）→ `UIFeedbackGenerator`
//  2. m3e_core 滑条震动：`m3e_haptics/haptics` → 同一套 `UIFeedbackGenerator`（带闸门）
//  3. 音乐节奏震动：`com.md3music.md3music/music_haptics`（Dart `MusicHapticsService`）
//     → `CoreHaptics`（跟随鼓点，熄屏后台播放也要震）
//
//  另含 `SpectrumFeatures`：从 FFT 幅度提取 20 维节拍特征向量，逐行移植自
//  Android `SpectrumFeatures.kt`（由 `AudioEqualizer.swift` 的频谱 tap 调用，
//  在发 `onFft` 的同时发 `onFeatures`）。
//
//  Android 端由 MainActivity.kt / MusicHapticsPlugin.kt 实现同名 channel；
//  iOS 在此补齐。仅 iPhone 有 Taptic 马达，iPad 上能力探测返回 false，
//  Dart 侧闸门自然关闭（不会出现"开关有效果但没震动"的假成功）。
//

import CoreHaptics
import Flutter
import UIKit

// MARK: - 交互震动与音乐震动的共享闸门

/// 进程级震动闸门：交互避让窗口 + m3e 滑条开关。
///
/// 交互震动与音乐震动驱动同一个 Taptic 马达，是单通道：音乐震动会打断用户刚点的
/// 按钮反馈，反之亦然。交互是用户主动发起的即时反馈，优先；音乐震动让位
/// [interactionSuppressSeconds]（在 130ms 冷却下最多丢一个鼓点）。
enum HapticsGate {
    /// 与 Android `MusicHapticsPlugin.INTERACTION_SUPPRESS_MS` 一致。
    static let interactionSuppressSeconds: TimeInterval = 0.150

    private static let interactionLock = NSLock()
    private static var lastInteractionUptime: TimeInterval = 0

    /// 由交互震动路径调用（等价 Android `MusicHapticsPlugin.noteInteraction()`）。
    static func noteInteraction() {
        let now = ProcessInfo.processInfo.systemUptime
        interactionLock.lock()
        lastInteractionUptime = now
        interactionLock.unlock()
    }

    static func suppressedByInteraction() -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        interactionLock.lock()
        let last = lastInteractionUptime
        interactionLock.unlock()
        return now - last < interactionSuppressSeconds
    }

    /// m3e_core 滑条震动的闸门（等价 Android `HapticsGate.sliderEnabled/sliderType`）。
    private static let sliderLock = NSLock()
    private static var _sliderEnabled = true
    private static var _sliderType: String?

    static var sliderEnabled: Bool {
        get { sliderLock.lock(); defer { sliderLock.unlock() }; return _sliderEnabled }
        set { sliderLock.lock(); _sliderEnabled = newValue; sliderLock.unlock() }
    }

    static var sliderType: String? {
        get { sliderLock.lock(); defer { sliderLock.unlock() }; return _sliderType }
        set { sliderLock.lock(); _sliderType = newValue; sliderLock.unlock() }
    }
}

// MARK: - 交互震动执行端（md3music/haptics + m3e_haptics/haptics）

/// 交互震动通道的执行端（对齐 Android `MainActivity.handleHapticVibrate`）。
///
/// 语义 type → 系统触感映射：
/// - `click` / `bookendLower`            → `UIImpactFeedbackGenerator(.light)`（EFFECT_CLICK）
/// - `tick` / `dragTexture`              → `UISelectionFeedbackGenerator`（EFFECT_TICK）
/// - `tickCrossing`                      → 按 amplitude 选 light / selection
/// - `heavy` / `bookendUpper`            → `UIImpactFeedbackGenerator(.heavy)`（EFFECT_HEAVY_CLICK）
/// - `double`                            → 两次 medium（EFFECT_DOUBLE_CLICK）
/// - `longPress`                         → 单次 medium（createOneShot(25)）
///
/// 未知 type 返回 false，让 Dart 端走 `HapticFeedback` 回落（与 Android 一致）。
final class HapticsBridge {
    static let shared = HapticsBridge()

    private static let mainChannelName = "md3music/haptics"
    private static let m3eChannelName = "m3e_haptics/haptics"

    /// 与 Android `handleHapticVibrate` 的 knownTypes 白名单逐字一致。
    private static let knownTypes: Set<String> = [
        "click", "bookendLower", "tick", "dragTexture", "tickCrossing",
        "heavy", "bookendUpper", "double", "longPress",
    ]

    private var mainChannel: FlutterMethodChannel?
    private var m3eChannel: FlutterMethodChannel?

    // 复用生成器：高频道（滑条刻度 / 列表行）避免每次新建
    private let light = UIImpactFeedbackGenerator(style: .light)
    private let medium = UIImpactFeedbackGenerator(style: .medium)
    private let heavy = UIImpactFeedbackGenerator(style: .heavy)
    private let selection = UISelectionFeedbackGenerator()

    private init() {}

    func attach(messenger: FlutterBinaryMessenger) {
        guard mainChannel == nil else { return }

        let main = FlutterMethodChannel(name: Self.mainChannelName, binaryMessenger: messenger)
        main.setMethodCallHandler { [weak self] call, result in
            switch call.method {
            case "vibrate":
                result(self?.handleVibrate(call, typeOverride: nil) ?? false)
            case "setSliderEnabled":
                let args = call.arguments as? [String: Any]
                HapticsGate.sliderEnabled = args?["enabled"] as? Bool ?? true
                HapticsGate.sliderType = args?["type"] as? String
                result(true)
            default:
                result(FlutterMethodNotImplemented)
            }
        }
        mainChannel = main

        let m3e = FlutterMethodChannel(name: Self.m3eChannelName, binaryMessenger: messenger)
        m3e.setMethodCallHandler { [weak self] call, result in
            switch call.method {
            case "vibrate":
                // 拦住时回 true 而非 error：m3e 的 applyTypedHaptic 只在 error 时回落
                // HapticFeedback，那样马达又被另一条路径驱动了（对齐 Android 注释）。
                if HapticsGate.sliderEnabled {
                    result(self?.handleVibrate(call, typeOverride: HapticsGate.sliderType) ?? false)
                } else {
                    result(true)
                }
            default:
                result(FlutterMethodNotImplemented)
            }
        }
        m3eChannel = m3e
    }

    /// 返回 true 表示已驱动马达（Dart 据此跳过 `HapticFeedback` 回落）。
    private func handleVibrate(_ call: FlutterMethodCall, typeOverride: String?) -> Bool {
        // 交互震动优先：通知音乐震动让位
        HapticsGate.noteInteraction()

        let args = call.arguments as? [String: Any]
        let type = typeOverride ?? args?["type"] as? String ?? ""
        let amplitude = args?["amplitude"] as? Double ?? 0.5
        guard Self.knownTypes.contains(type) else { return false }

        fire(type: type, amplitude: amplitude)
        return true
    }

    /// 必须在主线程驱动 `UIFeedbackGenerator`（通道回调本就在平台线程，仍做保护）。
    private func fire(type: String, amplitude: Double) {
        let play = { [weak self] in
            guard let self else { return }
            switch type {
            case "click", "bookendLower":
                self.light.prepare()
                self.light.impactOccurred()
            case "tick", "dragTexture":
                self.selection.prepare()
                self.selection.selectionChanged()
            case "tickCrossing":
                if amplitude >= 0.5 {
                    self.light.prepare()
                    self.light.impactOccurred()
                } else {
                    self.selection.prepare()
                    self.selection.selectionChanged()
                }
            case "heavy", "bookendUpper":
                self.heavy.prepare()
                self.heavy.impactOccurred()
            case "double":
                self.medium.prepare()
                self.medium.impactOccurred()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    guard let self else { return }
                    self.medium.prepare()
                    self.medium.impactOccurred()
                }
            case "longPress":
                self.medium.prepare()
                self.medium.impactOccurred()
            default:
                break
            }
        }
        if Thread.isMainThread {
            play()
        } else {
            DispatchQueue.main.async(execute: play)
        }
    }
}

// MARK: - 音乐节奏震动执行端（com.md3music.md3music/music_haptics）

/// 音乐节奏震动的执行端（对齐 Android `MusicHapticsPlugin`）。
///
/// **为什么用 `CoreHaptics` 而非 `UIFeedbackGenerator`**：音乐节拍是 2~8 次/秒的
/// 连续事件，需要按频带区分强度，且「始终启用」档要在熄屏后台播放时继续震动——
/// `CHHapticEngine` 挂在已激活的播放音频会话上（Info.plist 已声明 audio 后台模式），
/// 而 `UIFeedbackGenerator` 只在 App 前台有效。
///
/// **延迟补偿走在引擎时钟上**：`CHHapticPatternPlayer.start(atTime:)` 的时间轴就是
/// `CHHapticEngine.currentTime()`，把点火排在 `currentTime() + offset` 上，调用线程
/// （主线程）的抖动不会影响实际落点——比 Android 的 `ScheduledExecutorService` 更稳。
///
/// **总开关不在这里实现**：Dart 侧已读 `AppHaptics` 闸门决定是否下发。原生只多一层
/// 「交互避让」。
final class MusicHapticsEngine: NSObject {
    static let shared = MusicHapticsEngine()
    static let channelName = "com.md3music.md3music/music_haptics"

    /// 与 Android `maxOffsetMs` 一致。
    private static let maxOffsetMs = 600

    private var channel: FlutterMethodChannel?

    private var engine: CHHapticEngine?
    private var engineRunning = false
    private let supportsHaptics = CHHapticEngine.capabilitiesForHardware().supportsHaptics

    private let lock = NSLock()
    private var enabled = false
    private var waveform = "auto"
    private var offsetMs = 0
    private var kickStrength = 1.0
    private var snareStrength = 0.6

    /// 在途 player 强引用：`CHHapticPatternPlayer` 一旦释放，播放会立即中止。
    private var inFlightPlayers: [AnyObject] = []

    private override init() {
        super.init()
    }

    func attach(messenger: FlutterBinaryMessenger) {
        guard channel == nil else { return }

        let ch = FlutterMethodChannel(name: Self.channelName, binaryMessenger: messenger)
        ch.setMethodCallHandler { [weak self] call, result in
            guard let self else {
                result(nil)
                return
            }
            self.handle(call, result: result)
        }
        channel = ch

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )

        NSLog("[MD3Music] music haptics channel registered (supportsHaptics=\(supportsHaptics))")
    }

    // MARK: 通道分发

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "capabilities":
            // hasAmplitudeControl：CoreHaptics 始终支持 intensity 参数（0..1），
            // 因此与 supportsHaptics 同值——设置页「平滑」波形在 iPhone 上可选。
            result([
                "hasVibrator": supportsHaptics,
                "hasAmplitudeControl": supportsHaptics,
            ])

        case "outputLatency":
            // iOS 无 AudioTrack 排队深度概念（tap 挂 AVPlayer 音频图，量不到整条链路），
            // 返回 -1 让 Dart 保持手动补偿值并跳过自动校准。
            result(-1)

        case "configure":
            let args = call.arguments as? [String: Any]
            lock.lock()
            enabled = args?["enabled"] as? Bool ?? false
            waveform = args?["waveform"] as? String ?? "auto"
            offsetMs = min(max(args?["offsetMs"] as? Int ?? 0, 0), Self.maxOffsetMs)
            kickStrength = min(max(args?["kickStrength"] as? Double ?? 1.0, 0.0), 1.0)
            snareStrength = min(max(args?["snareStrength"] as? Double ?? 0.6, 0.0), 1.0)
            let nowEnabled = enabled
            lock.unlock()

            if nowEnabled {
                startEngineIfNeeded()
            } else {
                cancelAll()
            }
            NSLog("[MD3Music] music haptics configure enabled=\(nowEnabled) waveform=\(waveform) offsetMs=\(offsetMs)")
            result(true)

        case "strike":
            let args = call.arguments as? [String: Any]
            let kind = args?["kind"] as? String ?? "kick"
            let intensity = min(max(args?["intensity"] as? Double ?? 1.0, 0.0), 1.0)
            strike(kind: kind, intensity: intensity)
            result(true)

        case "stop":
            cancelAll()
            result(true)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: 点火

    private func strike(kind: String, intensity: Double) {
        lock.lock()
        let isEnabled = enabled
        let delay = Double(offsetMs) / 1000.0
        lock.unlock()

        guard isEnabled, supportsHaptics else { return }
        // 交互避让：用户刚点过按钮，这一拍让位（入队前先判一次）
        if HapticsGate.suppressedByInteraction() { return }

        ensureEngineRunning { [weak self] ok in
            guard ok, let self else { return }
            // 出队时再避让一次：引擎启动/延迟窗口内可能又发生了交互震动
            if HapticsGate.suppressedByInteraction() { return }
            self.play(kind: kind, intensity: intensity, delaySeconds: delay)
        }
    }

    private func play(kind: String, intensity: Double, delaySeconds: Double) {
        guard let engine, engineRunning else { return }
        lock.lock()
        let wave = waveform
        let base = kind == "snare" ? snareStrength : kickStrength
        lock.unlock()

        let amp = min(max(base * intensity, 0.0), 1.0)
        let isSnare = kind == "snare"
        // 结构性分层：snare 更"脆"、kick 更"闷"（对齐 Android kick 永不轻于 CLICK、
        // snare 永不重于 CLICK 的语义，这里用 sharpness 表达档次差异）
        let sharpness = isSnare ? 0.75 : 0.35

        let event: CHHapticEvent
        switch wave {
        case "pulse":
            event = CHHapticEvent(
                eventType: .hapticContinuous,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: Float(amp)),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: Float(sharpness)),
                ],
                relativeTime: 0,
                duration: 0.045
            )
        case "smooth":
            event = CHHapticEvent(
                eventType: .hapticContinuous,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: Float(amp)),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: Float(sharpness)),
                    CHHapticEventParameter(parameterID: .attackTime, value: 0.002),
                    CHHapticEventParameter(parameterID: .decayTime, value: 0.2),
                    CHHapticEventParameter(parameterID: .releaseTime, value: 0.05),
                    CHHapticEventParameter(parameterID: .sustained, value: 0),
                ],
                relativeTime: 0,
                duration: 0.25
            )
        default: // auto：清脆档，单次瞬态（对齐 Android createPredefined 的干净点击）
            event = CHHapticEvent(
                eventType: .hapticTransient,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: Float(amp)),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: Float(sharpness)),
                ],
                relativeTime: 0
            )
        }

        do {
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            let player = try engine.makePlayer(with: pattern)
            // 延迟排在引擎时钟上：不受调用线程抖动影响（见类注释）
            let startTime = delaySeconds > 0
                ? engine.currentTime + delaySeconds
                : CHHapticTimeImmediate
            try player.start(atTime: startTime)
            keepPlayerAlive(player, seconds: delaySeconds + 1.0)
        } catch {
            NSLog("[MD3Music] haptic strike failed: \(error)")
        }
    }

    /// 保留 player 到播放结束（释放会导致播放立即中止）。
    private func keepPlayerAlive(_ player: CHHapticPatternPlayer, seconds: TimeInterval) {
        lock.lock()
        inFlightPlayers.append(player)
        lock.unlock()
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.inFlightPlayers.removeAll { $0 === (player as AnyObject) }
            self.lock.unlock()
        }
    }

    /// 取消在途点火并停止当前触感（暂停 / 关开关 / seek / 特征断流）。
    private func cancelAll() {
        lock.lock()
        inFlightPlayers.removeAll()
        lock.unlock()
        engineRunning = false
        engine?.stop(completionHandler: nil)
    }

    // MARK: 引擎生命周期

    /// 引擎未运行时启动；已运行时同步回调，保证 `play` 能立刻拿到可用引擎。
    private func ensureEngineRunning(_ completion: @escaping (Bool) -> Void) {
        guard supportsHaptics else {
            completion(false)
            return
        }
        if engineRunning {
            completion(true)
            return
        }
        startEngineIfNeeded(completion)
    }

    private func startEngineIfNeeded(_ completion: ((Bool) -> Void)? = nil) {
        guard supportsHaptics else {
            completion?(false)
            return
        }
        if engineRunning {
            completion?(true)
            return
        }

        if engine == nil {
            do {
                let e = try CHHapticEngine()
                // 不自动关停：音乐震动在整首歌里持续点火，自动关停只会带来
                // "唱到一半不震了"的静默失效（下次 strike 才会重启）。
                e.isAutoShutdownEnabled = false
                e.stoppedHandler = { [weak self] reason in
                    guard let self else { return }
                    self.engineRunning = false
                    NSLog("[MD3Music] haptic engine stopped reason=\(reason.rawValue)")
                }
                e.resetHandler = { [weak self] in
                    // 媒体服务重置：引擎与 player 全部失效，丢弃后由下一次 strike 懒重建
                    guard let self else { return }
                    self.engineRunning = false
                    self.engine = nil
                    NSLog("[MD3Music] haptic engine reset")
                }
                engine = e
            } catch {
                NSLog("[MD3Music] CHHapticEngine init failed: \(error)")
                engine = nil
                completion?(false)
                return
            }
        }

        guard let engine else {
            completion?(false)
            return
        }
        engine.start { [weak self] error in
            guard let self else { return }
            if let error {
                NSLog("[MD3Music] haptic engine start failed: \(error)")
                completion?(false)
            } else {
                self.engineRunning = true
                completion?(true)
            }
        }
    }

    /// 回前台：若功能开着但引擎被系统回收，重新拉起。
    @objc private func handleDidBecomeActive() {
        lock.lock()
        let isEnabled = enabled
        lock.unlock()
        guard isEnabled else { return }
        startEngineIfNeeded()
    }
}

// MARK: - 节拍特征提取（移植自 Android SpectrumFeatures.kt）

/// 从一帧原始 FFT 幅度 + 时域样本提取 **20 维紧凑特征向量**，供 Dart 侧做
/// 节拍（onset）判定。
///
/// 布局（与 Dart `SpectrumFeaturesIndices` / Android `SpectrumFeatures` 一一对应）：
/// `[0..15]` 16 个对数频带能量（30Hz→16kHz，**未归一化**）、`[16]` 全带 RMS、
/// `[17]` 低频带(30–300Hz)、`[18]` 高频带(3–8kHz)、`[19]` 中频带(300Hz–3kHz)。
///
/// **为什么不复用 40 段视觉频带**：那是「逐帧自归一化 + 线性分箱」，分母是
/// `max(1.0, 帧内最大值)` —— 一种非线性、且音量相关的缩放。谱流量依赖帧间幅度的
/// **绝对关系**，被这样处理后动态范围已失真；且它只覆盖前 40 个线性 bin
/// （44.1kHz/1024 下 ≈0–1.7kHz），军鼓与镲的高频瞬态全部丢失。
///
/// **无状态**（除采样率变化时重建的频带表），可在音频线程反复调用。
final class SpectrumFeatures {
    static let count = 20

    private static let fMin = 30.0
    private static let fMax = 16000.0
    private static let lowLo = 30.0
    private static let lowHi = 300.0
    private static let midLo = 300.0
    private static let midHi = 3000.0
    private static let highLo = 3000.0
    private static let highHi = 8000.0

    private let fftSize: Int
    private let binCount: Int

    private var sampleRateHz = 0
    private var hzPerBin = 0.0
    private var logLo = [Int](repeating: 0, count: 16)
    private var logHi = [Int](repeating: 1, count: 16)
    private var lowLoIdx = 0
    private var lowHiIdx = 1
    private var midLoIdx = 0
    private var midHiIdx = 1
    private var highLoIdx = 0
    private var highHiIdx = 1

    init(fftSize: Int, binCount: Int) {
        self.fftSize = max(fftSize, 2)
        self.binCount = max(binCount, 2)
    }

    /// mags[i] 对应 FFT bin (i+1)，故频率 f 的下标是 f/hzPerBin - 1。
    private static func magIndex(_ hz: Double, _ hzPerBin: Double, _ binCount: Int) -> Int {
        let raw = Int(hz / hzPerBin) - 1
        return min(max(raw, 0), binCount - 1)
    }

    /// bin 表只在采样率真的变化时重建（一首歌内通常只发生一次）。
    private func ensureRate(_ rate: Int) {
        let effective = rate > 0 ? rate : 44100
        if effective == sampleRateHz { return }
        sampleRateHz = effective
        hzPerBin = Double(effective) / Double(fftSize)

        let ratio = SpectrumFeatures.fMax / SpectrumFeatures.fMin
        let bandCount = logLo.count
        for i in 0..<bandCount {
            let lo = SpectrumFeatures.fMin * pow(ratio, Double(i) / Double(bandCount))
            let hi = SpectrumFeatures.fMin * pow(ratio, Double(i + 1) / Double(bandCount))
            logLo[i] = SpectrumFeatures.magIndex(lo, hzPerBin, binCount)
            logHi[i] = max(logLo[i] + 1, SpectrumFeatures.magIndex(hi, hzPerBin, binCount))
        }
        // 顶带必须把 F_MAX 边界 bin 收进来：mean 是 [lo, hi) 左闭右开，内部频带的
        // 边界 bin 归上一带/下一带接住，而顶带之上没有频带，magIndex(F_MAX) 那一格
        // 会整体漏掉（44.1kHz/1024 下即 mags[370] ≈ 15978Hz，明明落在 16kHz 以内）。
        logHi[bandCount - 1] = max(
            logHi[bandCount - 1],
            SpectrumFeatures.magIndex(SpectrumFeatures.fMax, hzPerBin, binCount) + 1
        )

        lowLoIdx = SpectrumFeatures.magIndex(SpectrumFeatures.lowLo, hzPerBin, binCount)
        lowHiIdx = max(lowLoIdx + 1, SpectrumFeatures.magIndex(SpectrumFeatures.lowHi, hzPerBin, binCount))
        midLoIdx = SpectrumFeatures.magIndex(SpectrumFeatures.midLo, hzPerBin, binCount)
        midHiIdx = max(midLoIdx + 1, SpectrumFeatures.magIndex(SpectrumFeatures.midHi, hzPerBin, binCount))
        highLoIdx = SpectrumFeatures.magIndex(SpectrumFeatures.highLo, hzPerBin, binCount)
        highHiIdx = max(highLoIdx + 1, SpectrumFeatures.magIndex(SpectrumFeatures.highHi, hzPerBin, binCount))
    }

    /// 就地写入 `out`（长度必须为 [count]）。
    ///
    /// - mags: `SpectrumFft.magnitudesFrom` 的等价物（**未归一化**，长度 >= [binCount]）
    /// - samples: 同一帧的**未加窗**时域样本 —— RMS 用它算（加窗会给能量引入常数偏置，
    ///   而 Dart 侧做的是帧间差分，偏置会被抵消，故直接用原始样本更省一次遍历）。
    func extract(sampleRateHz rate: Int, mags: [Double], samples: [Float], out: inout [Double]) {
        precondition(out.count == SpectrumFeatures.count, "out must be \(SpectrumFeatures.count) long")
        ensureRate(rate)

        let bandCount = logLo.count
        for i in 0..<bandCount {
            out[i] = mean(mags, logLo[i], logHi[i])
        }

        var sq = 0.0
        for s in samples {
            let d = Double(s)
            sq += d * d
        }
        out[16] = samples.isEmpty ? 0 : (sq / Double(samples.count)).squareRoot()

        out[17] = mean(mags, lowLoIdx, lowHiIdx)
        out[19] = mean(mags, midLoIdx, midHiIdx)
        out[18] = mean(mags, highLoIdx, highHiIdx)
    }

    private func mean(_ mags: [Double], _ lo: Int, _ hi: Int) -> Double {
        guard !mags.isEmpty else { return 0 }
        let start = min(max(lo, 0), mags.count - 1)
        let end = min(max(hi, start + 1), mags.count)
        guard end > start else { return 0 }
        var sum = 0.0
        for b in start..<end { sum += mags[b] }
        return sum / Double(end - start)
    }
}
