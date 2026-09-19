import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../widgets/apple_lyrics/models/lyric_line.dart';

/// iOS 歌词悬浮窗：系统画中画（FaceTime 式 VideoCall contentSource）桥接。
///
/// 单行细条状悬浮条（300x22pt），无系统播放控件，点击小窗直接关闭；
/// 逐字卡拉OK渲染在原生端完成（参照 GlobalRefresh-PiP 的真机验证方案）。
/// 仅 iOS 激活；其它平台全部 no-op（Android 悬浮歌词走 FloatingLyricService，
/// 由 DesktopLyricService 原路径负责，互不影响）。
/// Swift 端实现见 ios/Runner/AppDelegate.swift 的 LyricsPipManager。
class LyricsPipService {
  LyricsPipService._();

  static final LyricsPipService instance = LyricsPipService._();

  static const MethodChannel _channel = MethodChannel(
    'com.md3music/lyrics_pip',
  );

  bool _handlerRegistered = false;
  bool _active = false;
  /// 歌词会话代际：每次整包歌词下发（切歌/新歌词就绪）+1，随 setLyrics/
  /// setLine/update 一起发给原生。原生只接受 generation 不小于当前值的更新，
  /// 迟到的旧歌消息直接丢弃，封死快速切歌时的乱序竞态。stop 时归零，
  /// 与原生端 didStop 的重置对称，下次开启两端从 0 重新对齐。
  int _generation = 0;

  /// PiP 窗口是否激活（start 成功置位；用户从 PiP 窗口关闭时由原生
  /// 'state' 回调复位）。按钮激活态以它为准。
  bool get active => _active;

  /// PiP 激活态变化回调（由 DesktopLyricService 注入，刷新按钮高亮）。
  void Function()? onActiveChanged;

  void _ensureHandler() {
    if (_handlerRegistered || !Platform.isIOS) return;
    _handlerRegistered = true;
    _channel.setMethodCallHandler(_handleMethodCall);
  }

  Future<dynamic> _handleMethodCall(MethodCall call) async {
    if (call.method == 'state') {
      final args = call.arguments;
      final isActive = args is Map ? args['active'] == true : false;
      _setActive(isActive);
    }
    return null;
  }

  /// 开关 PiP 悬浮窗，返回切换后的激活态（设备/系统不支持时保持 false）。
  Future<bool> toggle() async {
    if (_active) {
      await stop();
      return _active;
    }
    return start();
  }

  /// 启动 PiP 悬浮窗。乐观置位：窗口真正出现/启动失败由原生 'state'
  /// 回调校正（PictureInPictureControllerDelegate didStart/didStop）。
  Future<bool> start() async {
    if (!Platform.isIOS) return false;
    _ensureHandler();
    try {
      final ok = await _channel.invokeMethod<bool>('start');
      if (ok == true) _setActive(true);
      return _active;
    } catch (e) {
      debugPrint('[LyricsPip] start failed: $e');
      return false;
    }
  }

  Future<void> stop() async {
    if (!Platform.isIOS) return;
    try {
      await _channel.invokeMethod('stop');
    } catch (e) {
      debugPrint('[LyricsPip] stop failed: $e');
    }
    _generation = 0;
    _setActive(false);
  }

  /// 整包歌词下发（切歌/解析完成时调用）。[lines] 为解析后的统一歌词模型，
  /// 映射为原生期望的 {start: ms, duration: ms, text, translation} 行数组
  /// （原生用行尾时间算进度条总长）。
  Future<void> setLyrics(List<LyricLine> lines) async {
    if (!Platform.isIOS || !_active) return;
    _ensureHandler();
    final gen = ++_generation;
    try {
      await _channel.invokeMethod('setLyrics', <String, dynamic>{
        'generation': gen,
        'lines': lines
            .map(
              (l) => <String, dynamic>{
                'start': l.startTime,
                'duration': l.duration,
                'text': l.text,
                'translation': l.translation ?? '',
              },
            )
            .toList(),
      });
    } catch (e) {
      debugPrint('[LyricsPip] setLyrics failed: $e');
    }
  }

  /// 当前行下发（行切换时调用）。原生以 [positionMs] 为锚点 + 单调钟
  /// 自推进逐字进度；[placeholder] 非空时原生显示占位文案。
  Future<void> setLine({
    required String text,
    required int lineStart,
    required List<LyricWord> words,
    required String placeholder,
    required int positionMs,
    required bool playing,
  }) async {
    if (!Platform.isIOS || !_active) return;
    try {
      await _channel.invokeMethod('setLine', <String, dynamic>{
        'generation': _generation,
        'text': text,
        'lineStart': lineStart,
        'placeholder': placeholder,
        'positionMs': positionMs,
        'playing': playing,
        'words': [
          for (final w in words)
            <String, dynamic>{'t': w.text, 's': w.startTime, 'd': w.duration},
        ],
      });
    } catch (e) {
      debugPrint('[LyricsPip] setLine failed: $e');
    }
  }

  /// 播放进度/状态校准。与 NowPlayingService 同源：~500ms 节流 + 状态翻转
  /// /seek 立即推；原生端以最近一次推送为锚点自推进，重复位置无副作用。
  Future<void> update({required int positionMs, required bool playing}) async {
    if (!Platform.isIOS || !_active) return;
    try {
      await _channel.invokeMethod('update', <String, dynamic>{
        'generation': _generation,
        'position': positionMs,
        'playing': playing,
      });
    } catch (e) {
      debugPrint('[LyricsPip] update failed: $e');
    }
  }

  void _setActive(bool value) {
    if (_active == value) return;
    _active = value;
    onActiveChanged?.call();
  }
}
