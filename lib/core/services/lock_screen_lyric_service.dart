import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// iOS 锁屏歌词（Live Activity，16.1+）桥接。
///
/// 数据协议与 Android LockScreenLyricActivity 同构（由
/// DesktopLyricService 喂入，见原生 LyricLiveActivityController.swift
/// 与扩展侧 MD3Widget.swift）：
/// - setLyrics：整首歌词 lines（text/start/duration/words/wordStarts/
///   wordDurations/sub）写入 App Group 文件 la_lyrics.json；
///   封面模糊图由原生按 songId 自理（取 WidgetSync 的 widget_cover.png）
/// - update：轻量状态（行下标/位置/播放态/样式色）→ ContentState
/// - setAccent：封面主色（异步提取完成时），跟 Android
///   updateLockScreenAccent 同语义
///
/// 行内逐字进度由扩展侧 TimelineView 按墙钟自推进（positionMs +
/// now - updatedAt），Dart 只在 切行 / seek / 播放态 / 样式 变化时推
/// ContentState（本类去重）。低版本 iOS / 未签名环境所有调用安静失败。
class LockScreenLyricService {
  LockScreenLyricService._();
  static final instance = LockScreenLyricService._();

  static const _channel = MethodChannel(
    'com.md3music.md3music/lyric_live_activity',
  );

  bool _supported = true;
  bool _enabled = false;
  String? _lastSongId;
  List<Object?>? _lastLines;
  int _rev = 0;

  // ContentState 去重基线
  int? _lastLineIndex;
  bool? _lastIsPlaying;
  String? _lastPlaceholder;
  String? _lastTitle;
  String? _lastArtist;
  int? _lastAccent;
  bool? _lastUseDynamic;
  bool? _lastShowSub;
  double? _lastFontSize;
  int _lastDurationMs = -1;

  /// 切歌 / 开关时重置全部去重基线，下个 tick 全量重推
  void reset() {
    _lastSongId = null;
    _lastLines = null;
    _lastLineIndex = null;
    _lastIsPlaying = null;
    _lastPlaceholder = null;
    _lastTitle = null;
    _lastArtist = null;
    _lastAccent = null;
    _lastUseDynamic = null;
    _lastShowSub = null;
    _lastFontSize = null;
    _lastDurationMs = -1;
  }

  Future<void> setEnabled(bool enabled) async {
    if (_enabled == enabled) return;
    _enabled = enabled;
    reset();
    if (!enabled) {
      try {
        await _channel.invokeMethod('setEnabled', {'enabled': false});
      } catch (_) {}
      return;
    }
    try {
      final ok = await _channel.invokeMethod<bool>('setEnabled', {
        'enabled': true,
      });
      _supported = ok ?? false;
    } catch (_) {
      _supported = false;
    }
  }

  bool get supported => _supported;

  /// 整首歌词（[lines] 与 Android updateLockScreenLyricData 的 lines 同构，
  /// 原样透传）；只在内容变化时写文件。整包推送后 rev+1，扩展端据此重读。
  Future<void> setLyrics(String songId, List<Object?> lines) async {
    if (!_enabled || !_supported) return;
    if (_lastSongId == songId &&
        _lastLines != null &&
        _listEquals(_lastLines!, lines)) {
      return;
    }
    _lastSongId = songId;
    _lastLines = lines;
    _rev++;
    try {
      await _channel.invokeMethod('setLyrics', {
        'songId': songId,
        'lines': lines,
      });
    } catch (e) {
      debugPrint('[LockScreenLyric] setLyrics failed: $e');
    }
  }

  /// 轻量状态推送（DesktopLyricService 已保证只在切行/seek/播放态/样式
  /// 变化时进入，这里再做字段级去重）。位置不参与去重：每次调用都作为
  /// 扩展端墙钟推进的新基准。
  Future<void> update({
    required String songId,
    required int lineIndex,
    required int positionMs,
    required int durationMs,
    required bool isPlaying,
    required String placeholder,
    required String title,
    required String artist,
    required int accent,
    required bool useDynamic,
    required bool showSub,
    required double fontSize,
  }) async {
    if (!_enabled || !_supported) return;
    final unchanged =
        lineIndex == _lastLineIndex &&
        isPlaying == _lastIsPlaying &&
        placeholder == _lastPlaceholder &&
        title == _lastTitle &&
        artist == _lastArtist &&
        accent == _lastAccent &&
        useDynamic == _lastUseDynamic &&
        showSub == _lastShowSub &&
        fontSize == _lastFontSize &&
        durationMs == _lastDurationMs;
    if (unchanged) return;
    _lastLineIndex = lineIndex;
    _lastIsPlaying = isPlaying;
    _lastPlaceholder = placeholder;
    _lastTitle = title;
    _lastArtist = artist;
    _lastAccent = accent;
    _lastUseDynamic = useDynamic;
    _lastShowSub = showSub;
    _lastFontSize = fontSize;
    _lastDurationMs = durationMs;
    try {
      await _channel.invokeMethod('update', {
        'songId': songId,
        'rev': _rev,
        'lineIndex': lineIndex,
        'positionMs': positionMs,
        'durationMs': durationMs,
        'isPlaying': isPlaying,
        'placeholder': placeholder,
        'title': title,
        'artist': artist,
        'accent': accent,
        'useDynamic': useDynamic,
        'showSub': showSub,
        'fontSize': fontSize,
      });
    } catch (e) {
      debugPrint('[LockScreenLyric] update failed: $e');
    }
  }

  static bool _listEquals(List<Object?> a, List<Object?> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      final x = a[i], y = b[i];
      if (x is Map && y is Map) {
        if (x.length != y.length) return false;
        for (final k in x.keys) {
          if (x[k] != y[k]) return false;
        }
      } else if (x != y) {
        return false;
      }
    }
    return true;
  }
}
