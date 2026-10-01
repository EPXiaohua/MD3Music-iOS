import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:material_ui/material_ui.dart' as mui;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/utils/app_toast.dart';
import '../../main.dart' show appNavigatorKey;
import '../../services/kugou_api/kugou_api_client.dart';
import 'recognition_utils.dart';
import 'song_recognition_page.dart';

/// iOS 听歌识曲悬浮窗控制器（系统画中画）。
///
/// iOS 没有 Android AudioPlaybackCapture（系统音频捕获）的对应能力，
/// 悬浮窗识别走与识曲页相同的麦克风链路：本控制器驱动 8s/段、最多 56s 的
/// 录音+识别循环，原生侧（SongRecognitionPipManager）只负责渲染 2:1 PiP
/// 窗口，状态经 update 推送（idle/listening/recognizing/result/stopped）。
///
/// 交互：
/// - 识曲页「悬浮窗模式」开窗后**立即开始识别循环**（iOS 悬浮窗内部不可点，
///   识别不依赖窗口交互）；窗口配色经 setThemeColors 同步应用主题
///   （莫奈/动态取色 + 深浅色模式自适应）；
/// - 轻点悬浮窗浮现系统按钮：点「还原」回前台即退出悬浮模式（小窗不重开，
///   循环停止）；点「关闭(X)」同样结束悬浮模式；
/// - 识别到歌后保存未读结果：回前台或重新打开应用时自动打开识曲页展示；
///   识曲页已打开时直接在该页展示，防重复弹页。
class PipRecognitionController {
  PipRecognitionController._() {
    // App 回前台时：若有悬浮窗识别出的未读结果，打开识曲页展示
    _lifecycleListener = AppLifecycleListener(
      onResume: () {
        unawaited(openPendingResultPageIfAny());
      },
    );
  }
  static final PipRecognitionController instance = PipRecognitionController._();

  // 故意持有：AppLifecycleListener 需保持引用存活，dispose 时才需要访问
  // ignore: unused_field
  late final AppLifecycleListener _lifecycleListener;

  static const MethodChannel _channel = MethodChannel(
    'com.md3music/recognition_pip',
  );

  /// 未消费识别结果的本地存储 key（跨会话，覆盖"识别后杀掉 App 再打开"）
  static const String _prefsResultKey = 'pip_recognition_pending_result';

  /// 未读结果保留时长：超过后不再自动打开识曲页（避免陈旧结果突兀弹出）
  static const Duration _pendingResultTtl = Duration(minutes: 10);

  /// 每段录制时长（秒），与识曲页/安卓悬浮窗一致
  static const int _segmentDuration = 8;

  /// 最大总录制时长（秒），56s = 7 轮
  static const int _maxTotalDuration = 56;

  /// 录音采样率（44100Hz，与识曲页一致）
  static const int _recordSampleRate = 44100;

  /// 目标采样率（酷狗指纹接口要求 8000Hz）
  static const int _targetSampleRate = 8000;

  final AudioRecorder _recorder = AudioRecorder();

  /// 小窗应保持打开（未被用户/主动 stop 关闭）
  bool _windowWanted = false;
  bool _isActive = false;
  bool _isLooping = false;
  int _attemptCount = 0;

  /// 悬浮窗模式是否开启（小窗存活中）
  bool get isActive => _isActive;

  /// 识别循环是否进行中
  bool get isLooping => _isLooping;

  // 状态变化监听（识曲页入口按钮刷新）
  final List<VoidCallback> _listeners = [];
  void addListener(VoidCallback cb) => _listeners.add(cb);
  void removeListener(VoidCallback cb) => _listeners.remove(cb);
  void _notify() {
    for (final cb in List.of(_listeners)) {
      cb();
    }
  }

  /// 开启悬浮窗模式：打开 PiP 小窗并直接开始识别循环
  /// （iOS 悬浮窗内部不可点，不依赖还原按钮触发识别）。
  Future<bool> start() async {
    if (_isActive) return true;
    _channel.setMethodCallHandler(_onNativeCall);
    bool ok = false;
    try {
      ok = await _channel.invokeMethod<bool>('start') ?? false;
    } catch (e) {
      print('[PipRecognition] native start failed: $e');
    }
    if (!ok) return false;
    _windowWanted = true;
    _isActive = true;
    _notify();
    _pushState('idle', text: '点击开始听歌识曲');
    // 直接开始识别（麦克风权限弹窗等准备期间小窗显示 idle 文案）
    unawaited(startLoop());
    return true;
  }

  /// 关闭悬浮窗模式：停止识别循环并关闭小窗
  Future<void> stop() async {
    _windowWanted = false;
    await _abortLoop();
    try {
      await _channel.invokeMethod('stop');
    } catch (_) {}
    _isActive = false;
    _notify();
  }

  // ===================== 识别结果的回前台/冷启动展示 =====================

  /// 未消费的识别结果（内存缓存，持久化见 _storePendingResult）
  Map<String, dynamic>? _pendingResult;

  /// 保存识别结果：内存 + 本地持久化（跨会话，覆盖杀掉 App 再打开的场景）
  Future<void> _storePendingResult(Map<String, dynamic> response) async {
    _pendingResult = response;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _prefsResultKey,
        jsonEncode({
          'ts': DateTime.now().millisecondsSinceEpoch,
          'response': response,
        }),
      );
    } catch (e) {
      print('[PipRecognition] save pending result failed: $e');
    }
  }

  /// 取走未消费的识别结果（读后即清）。
  /// 超过保留时长（10 分钟）的陈旧结果直接丢弃，不再自动打开识曲页。
  Future<Map<String, dynamic>?> takePendingResult() async {
    final memory = _pendingResult;
    _pendingResult = null;
    // 无论内存是否命中，持久化一律清掉：内存命中时不清，回前台/再次打开
    // 识曲页会从 prefs 重复读到同一结果，导致结果展示两遍
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsResultKey);
      if (raw != null) await prefs.remove(_prefsResultKey);
      if (memory != null) return memory;
      if (raw == null) return null;
      final wrapper = jsonDecode(raw);
      if (wrapper is! Map || wrapper['response'] is! Map) return null;
      final ts = wrapper['ts'];
      if (ts is! int ||
          DateTime.now().millisecondsSinceEpoch - ts >
              _pendingResultTtl.inMilliseconds) {
        return null;
      }
      return Map<String, dynamic>.from(wrapper['response'] as Map);
    } catch (e) {
      print('[PipRecognition] load pending result failed: $e');
      return null;
    }
  }

  /// 有未消费的悬浮窗识别结果时，打开识曲页展示。
  /// 回前台（AppLifecycleListener.onResume）与冷启动（app.dart 首帧后）都会调用。
  /// 识曲页已打开（且在栈顶）时直接在该页展示，防重复弹页。
  Future<void> openPendingResultPageIfAny() async {
    final result = await takePendingResult();
    if (result == null) return;
    // 识曲页已打开：交给页面直接展示；页面不在栈顶时返回 false 走 push
    final sink = _activePageSink;
    if (sink != null && sink(result)) return;
    final navigator = appNavigatorKey.currentState;
    if (navigator == null) {
      print('[PipRecognition] navigator not ready, drop pending result');
      return;
    }
    unawaited(
      navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => SongRecognitionPage(initialResult: result),
        ),
      ),
    );
  }

  /// 当前存活识曲页的结果展示回调（防重复弹页）。
  /// 页面 initState 注册、dispose 注销；返回 false 表示页面无法立即展示
  /// （不在栈顶），控制器改走 push 新页面。
  bool Function(Map<String, dynamic> result)? _activePageSink;

  void attachPageSink(bool Function(Map<String, dynamic> result) sink) {
    _activePageSink = sink;
  }

  void detachPageSink(bool Function(Map<String, dynamic> result) sink) {
    if (_activePageSink == sink) _activePageSink = null;
  }

  // ===================== 主题配色同步（莫奈/动态取色 + 深浅色自适应） =====================

  /// 把应用当前 ColorScheme 的关键 token 推送给原生窗口渲染。
  /// 浅色主题推近白的 surface 面板，深色主题推深色容器——原生不做任何
  /// 颜色计算，只按推送值渲染，深浅匹配由 Dart 侧的 colorScheme 天然完成。
  /// 注意：页面里 Theme.of(context).colorScheme 是 material_ui 包的
  /// ColorScheme，故此处也收 mui.ColorScheme。
  Future<void> pushThemeColors(mui.ColorScheme cs) async {
    // 浅色面板用 surface（主题里最贴白的底色），深色面板用 surfaceContainer
    // （深色容器色，与旧版深色窗口观感一致）
    final isDark = cs.brightness == Brightness.dark;
    try {
      await _channel.invokeMethod('setThemeColors', {
        'panel': (isDark ? cs.surfaceContainer : cs.surface).toARGB32(),
        'idleCircle': cs.surfaceContainerHighest.toARGB32(),
        'onSurface': cs.onSurface.toARGB32(),
        'onSurfaceVariant': cs.onSurfaceVariant.toARGB32(),
        'error': cs.error.toARGB32(),
        'onError': cs.onError.toARGB32(),
        'tertiary': cs.tertiary.toARGB32(),
        'onTertiary': cs.onTertiary.toARGB32(),
        'resultBg': cs.primaryContainer.toARGB32(),
        'onResult': cs.onPrimaryContainer.toARGB32(),
      });
    } catch (_) {}
  }

  Future<dynamic> _onNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'state':
        final args = call.arguments as Map?;
        final active = args?['active'] == true;
        if (active) {
          if (!_isActive) {
            _isActive = true;
            _notify();
          }
        } else if (_windowWanted) {
          // 用户用系统 X / 还原键关闭小窗：结束悬浮模式（识别循环一并停止）。
          // 还原键不重开小窗——回前台即退出悬浮模式；若有识别结果，
          // 回前台的 onResume 会自动打开识曲页展示。
          _windowWanted = false;
          await _abortLoop();
          _isActive = false;
          _notify();
        }
        break;
    }
    return null;
  }

  // ===================== 识别循环（麦克风，与识曲页同链路） =====================

  /// 启动识别循环。返回 false 表示麦克风权限被拒等无法开始的情况。
  Future<bool> startLoop() async {
    if (_isLooping) return true;
    final mic = await Permission.microphone.request();
    if (!mic.isGranted) {
      showToast('需要麦克风权限才能使用听歌识曲', long: true);
      return false;
    }
    _isLooping = true;
    _attemptCount = 0;
    _notify();

    // 切换音频会话为录音模式（与识曲页一致）
    try {
      final session = await AudioSession.instance;
      await session.configure(
        const AudioSessionConfiguration(
          avAudioSessionCategory: AVAudioSessionCategory.playAndRecord,
          avAudioSessionMode: AVAudioSessionMode.defaultMode,
          androidAudioAttributes: AndroidAudioAttributes(
            contentType: AndroidAudioContentType.music,
            usage: AndroidAudioUsage.media,
          ),
          androidWillPauseWhenDucked: false,
        ),
      );
    } catch (_) {}

    try {
      while (_isLooping) {
        final elapsed = _attemptCount * _segmentDuration;
        if (elapsed >= _maxTotalDuration) {
          // 超时未识别到
          _pushState('stopped', text: '未识别到歌曲');
          break;
        }
        _attemptCount++;
        _pushState(
          'listening',
          text:
              '正在聆听... ${_attemptCount * _segmentDuration}s / ${_maxTotalDuration}s',
        );
        final wav = await _recordSegment();
        if (!_isLooping) break;
        _pushState('recognizing', text: '正在识别第 $_attemptCount 段...');
        final matched = await _recognizeSegment(wav);
        if (!_isLooping) break;
        if (matched != null) {
          // 保存未读结果：回前台/重新打开应用时自动打开识曲页展示
          await _storePendingResult(matched.response);
          _pushState('result', songName: matched.name, artist: matched.artist);
          // App 在前台时（悬浮窗浮于应用之上）不会有 resume 事件，
          // 结果一出直接打开识曲页展示；后台时 push 同样安全（回前台已在栈顶）
          unawaited(openPendingResultPageIfAny());
          break;
        }
      }
    } catch (e) {
      print('[PipRecognition] loop error: $e');
      if (_isLooping) _pushState('stopped', text: '未识别到歌曲');
    } finally {
      _isLooping = false;
      await _releaseRecorderAndSession();
      _notify();
    }
    return true;
  }

  /// 中途停止循环（关窗/stop()）：只停录音与会话，不向窗口推状态
  Future<void> _abortLoop() async {
    if (!_isLooping) return;
    _isLooping = false;
    await _releaseRecorderAndSession();
    _notify();
  }

  Future<void> _releaseRecorderAndSession() async {
    try {
      await _recorder.stop();
    } catch (_) {}
    try {
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration.music());
    } catch (_) {}
  }

  /// 录一段 8s WAV（unprocessed 源，失败回退 mic）
  Future<Uint8List?> _recordSegment() async {
    final dir = await getTemporaryDirectory();
    final path =
        '${dir.path}/pip_recog_${DateTime.now().millisecondsSinceEpoch}.wav';
    RecordConfig configFor(AndroidAudioSource source) => RecordConfig(
      encoder: AudioEncoder.wav,
      sampleRate: _recordSampleRate,
      numChannels: 1,
      autoGain: false,
      echoCancel: false,
      noiseSuppress: false,
      androidConfig: AndroidRecordConfig(
        audioSource: source,
        audioManagerMode: AudioManagerMode.modeNormal,
      ),
    );
    try {
      await _recorder.start(
        configFor(AndroidAudioSource.unprocessed),
        path: path,
      );
    } catch (_) {
      try {
        await _recorder.start(configFor(AndroidAudioSource.mic), path: path);
      } catch (e) {
        print('[PipRecognition] start recorder failed: $e');
        // 启动失败按整段静音处理，等满段时长避免 busy-loop
        await Future.delayed(const Duration(seconds: _segmentDuration));
        return null;
      }
    }
    await Future.delayed(const Duration(seconds: _segmentDuration));
    if (!_isLooping) {
      try {
        await _recorder.stop();
      } catch (_) {}
      return null;
    }
    String? stopped;
    try {
      stopped = await _recorder.stop();
    } catch (e) {
      print('[PipRecognition] stop recorder error: $e');
    }
    if (stopped == null || stopped.isEmpty) return null;
    try {
      final file = File(stopped);
      final bytes = await file.readAsBytes();
      await file.delete().catchError((_) => file);
      return bytes;
    } catch (_) {
      return null;
    }
  }

  /// 识别一段：静音检测 → 增益归一化 → 酷狗 audioMatch。
  /// 返回命中的歌名/歌手/完整响应（识曲页结果卡片要用完整响应）；
  /// 未命中返回 null。
  Future<({String name, String artist, Map<String, dynamic> response})?>
  _recognizeSegment(Uint8List? wav) async {
    try {
      if (wav == null || wav.isEmpty) return null;
      // 优先用本地 Rust 服务器做 PCM 前处理，失败降级 Dart 实现（与识曲页一致）
      final rustResult = await processPcmWithRust(
        input: wav,
        fromHz: _recordSampleRate,
        toHz: _targetSampleRate,
      );
      Uint8List pcmData;
      int maxAmplitude;
      if (rustResult != null) {
        pcmData = rustResult.pcm;
        maxAmplitude = rustResult.maxAmplitude;
      } else {
        final rawPcm = _extractPcmFromWav(wav);
        pcmData = downsamplePcm(rawPcm, _recordSampleRate, _targetSampleRate);
        maxAmplitude = computeMaxAmplitude(pcmData);
        if (maxAmplitude >= kSilenceAmplitudeThreshold) {
          pcmData = normalizeGain(pcmData, maxAmplitude);
        }
      }
      // 静音段跳过
      if (maxAmplitude < kSilenceAmplitudeThreshold) return null;

      final response = await KugouApiClient().audioMatch(pcmData);
      if (response == null || !hasSongData(response)) return null;
      final audioInfo = _extractAudioInfo(response);
      final name =
          extractField(audioInfo, [
            'songname',
            'song_name',
            'name',
            'SongName',
          ]) ??
          '未知歌曲';
      final artistName =
          extractField(audioInfo, [
            'singername',
            'singer_name',
            'artist',
            'SingerName',
          ]) ??
          '';
      return (name: name, artist: artistName, response: response);
    } catch (e) {
      print('[PipRecognition] recognize error: $e');
      return null;
    }
  }

  /// 从 audioMatch response 解析出歌曲信息 map（data 第一项），
  /// 与悬浮识曲/识曲页的解析逻辑一致。
  Map<String, dynamic>? _extractAudioInfo(Map<String, dynamic> response) {
    final responseData = response['data'];
    if (responseData is List && responseData.isNotEmpty) {
      final first = responseData.first;
      if (first is Map) {
        return Map<String, dynamic>.from(first);
      }
    }
    if (responseData is Map) {
      return Map<String, dynamic>.from(responseData);
    }
    return null;
  }

  Uint8List _extractPcmFromWav(List<int> bytes) {
    if (bytes.length < 44) return Uint8List.fromList(bytes);
    if (bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46) {
      for (int i = 12; i < bytes.length - 4; i++) {
        if (bytes[i] == 0x64 &&
            bytes[i + 1] == 0x61 &&
            bytes[i + 2] == 0x74 &&
            bytes[i + 3] == 0x61) {
          final pcmStart = i + 8;
          if (pcmStart < bytes.length) {
            return Uint8List.fromList(bytes.sublist(pcmStart));
          }
        }
      }
    }
    return Uint8List.fromList(bytes);
  }

  // ===================== 状态推送（原生窗口渲染用） =====================

  Future<void> _pushState(
    String state, {
    String? text,
    String songName = '',
    String artist = '',
  }) async {
    try {
      await _channel.invokeMethod('update', {
        'state': state,
        'text': text ?? '',
        'songName': songName,
        'artist': artist,
      });
    } catch (_) {}
  }
}
