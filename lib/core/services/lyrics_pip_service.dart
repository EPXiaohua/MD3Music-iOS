import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../widgets/apple_lyrics/models/lyric_line.dart';

/// iOS 歌词悬浮窗：系统画中画（FaceTime 式 VideoCall contentSource）桥接。
///
/// 单行细条状悬浮条（300x22pt），无系统播放控件，点击小窗直接关闭；
/// 逐字卡拉OK渲染在原生端完成（参照 github.com/CaiWanFeng/PiP 项目）。
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

  /// 最近一次用户开关意图（toggle 翻转）。快速连点时每次都把最终意图发给
  /// 原生，由原生状态机收敛；按钮激活态 [_active] 严格跟原生 didStart/didStop
  /// 的 'state' 回调走，不做乐观置位。
  bool _desiredActive = false;

  /// PiP 窗口是否激活。严格由原生 didStart/didStop 的 'state' 回调驱动
  /// （含用户从 PiP 窗口关闭/系统手势划掉小窗），按钮激活态以它为准。
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

  /// 开关 PiP 悬浮窗，返回当前激活态。激活态由原生回调驱动，快速连点时
  /// 这里只负责翻转并下发最终意图（原生状态机收敛）；设备/系统不支持时
  /// 意图回退并保持 false。
  Future<bool> toggle() async {
    _desiredActive = !_desiredActive;
    if (_desiredActive) {
      final ok = await start();
      if (!ok) _desiredActive = false;
    } else {
      await stop();
    }
    return _active;
  }

  /// 启动 PiP 悬浮窗（下发开启意图）。原生 startPictureInPicture 是异步
  /// 指令，这里不乐观置位 [_active]；激活成功/失败由原生 'state' 回调
  /// （didStart/didStop/failedToStart）驱动。返回 false 表示请求被拒
  /// （设备/系统不支持或通道异常）。
  Future<bool> start() async {
    if (!Platform.isIOS) return false;
    _ensureHandler();
    try {
      final ok = await _channel.invokeMethod<bool>('start');
      return ok == true;
    } catch (e) {
      debugPrint('[LyricsPip] start failed: $e');
      return false;
    }
  }

  /// 关闭 PiP 悬浮窗（下发关闭意图）。激活态同样由原生 'state' 回调复位，
  /// 这里不本地置位（与原生状态机保持单一事实源）。
  Future<void> stop() async {
    if (!Platform.isIOS) return;
    try {
      await _channel.invokeMethod('stop');
    } catch (e) {
      debugPrint('[LyricsPip] stop failed: $e');
    }
  }

  /// 整包歌词下发（切歌/解析完成时调用）。[lines] 为解析后的统一歌词模型，
  /// 映射为原生期望的 {start: ms, duration: ms, text, translation} 行数组
  /// （原生用行尾时间算进度条总长）。
  Future<void> setLyrics(List<LyricLine> lines) async {
    if (!Platform.isIOS || !_active) return;
    _ensureHandler();
    try {
      await _channel.invokeMethod('setLyrics', <String, dynamic>{
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
