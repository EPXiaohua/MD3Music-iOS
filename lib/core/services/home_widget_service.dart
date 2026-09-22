import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 桌面小组件服务：通过 MethodChannel 向原生 Android AppWidget 推送播放状态。
///
/// 调用时机：播放/暂停、切歌、进度更新（节流）时调用 [updateWidget]。
/// 原生侧 MusicWidgetProvider 接收广播后刷新 RemoteViews。
class HomeWidgetService {
  static const _channel = MethodChannel('com.md3music.md3music/home_widget');

  /// 更新桌面小组件显示内容。
  ///
  /// 封面由原生侧从 MediaSession 缓存同步，无需 Flutter 传递路径。
  static Future<void> updateWidget({
    required String title,
    required String artist,
    required bool isPlaying,
    required Duration position,
    required Duration duration,
  }) async {
    try {
      await _channel.invokeMethod('updateWidget', {
        'title': title,
        'artist': artist,
        'isPlaying': isPlaying,
        'position': position.inMilliseconds,
        'duration': duration.inMilliseconds,
      });
    } catch (e) {
      debugPrint('HomeWidgetService.updateWidget error: $e');
    }
  }

  /// 更新私人FM桌面小组件。
  ///
  /// [snapshot] 为扁平键值对（含嵌套的 colors 主题色表），由 MainActivity 转发为
  /// 广播 extras，PersonalFmWidgetProvider 据此重绘 RemoteViews。封面由原生侧
  /// 按 coverUrl/nextCover 自行下载缓存，无需 Flutter 传位图。
  static Future<void> updateFmWidget({
    required Map<String, Object?> snapshot,
  }) async {
    try {
      await _channel.invokeMethod('updateFmWidget', snapshot);
    } catch (e) {
      debugPrint('HomeWidgetService.updateFmWidget error: $e');
    }
  }

  /// 向音乐播放器小组件推送当前主题色（color_* extras，文本走原生缓存）。
  /// [colors] 为 ColorScheme 色角色名到 ARGB 值的映射。
  static Future<void> updateMusicWidgetTheme({
    required Map<String, int> colors,
  }) async {
    try {
      await _channel.invokeMethod('updateMusicWidgetTheme', colors);
    } catch (e) {
      debugPrint('HomeWidgetService.updateMusicWidgetTheme error: $e');
    }
  }

  /// 注册桌面小组件按钮命令回调（iOS 17 AppIntent：播放/暂停、下一首）。
  ///
  /// widget 按钮把命令写入 App Group 并打开 app，原生回前台时经
  /// invokeMethod("widgetCommand") 转发到此处；[onCommand] 收到
  /// "play_pause" / "next" 等动作后执行对应播放控制。
  static void setCommandHandler(Future<void> Function(String action) onCommand) {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'widgetCommand') {
        final args = call.arguments as Map?;
        final action = args?['action'] as String?;
        if (action != null) await onCommand(action);
      }
      return null;
    });
  }
}
