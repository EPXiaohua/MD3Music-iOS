import 'package:material_ui/material_ui.dart';
import 'package:m3e_core/m3e_core.dart';

import '../../core/utils/app_toast.dart';
import '../../providers/player_provider.dart';

/// 睡眠定时药丸的视觉风格。
///
/// 标准版跟随主题容器色；AM 版是深色蒙版上的半透明白底。
class SleepTimerPillStyle {
  const SleepTimerPillStyle({
    required this.backgroundColor,
    required this.foregroundColor,
  });

  final Color backgroundColor;
  final Color foregroundColor;

  /// 标准（MD3E）：primaryContainer / onPrimaryContainer。
  static SleepTimerPillStyle standardOf(BuildContext context) =>
      SleepTimerPillStyle(
        backgroundColor: Theme.of(context).colorScheme.primaryContainer,
        foregroundColor: Theme.of(context).colorScheme.onPrimaryContainer,
      );

  /// AM：白色 15% 底 + 纯白前景。
  static SleepTimerPillStyle amOf() => SleepTimerPillStyle(
    backgroundColor: Colors.white.withValues(alpha: 0.15),
    foregroundColor: Colors.white,
  );
}

/// 睡眠定时剩余时间格式化：>=1h 显示 `XhYYm`，否则 `mm:ss`。
String formatSleepTimerRemaining(Duration d) {
  if (d.inHours >= 1) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    return '${h}h${m.toString().padLeft(2, '0')}m';
  }
  final m = d.inMinutes;
  final s = d.inSeconds.remainder(60);
  return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
}

/// 顶栏睡眠定时药丸。
///
/// 可见性由内部判定，调用方无需判空：
/// - [SleepTimerMode.off] → [SizedBox.shrink]
/// - [SleepTimerMode.endOfTrack]（到点等待态，无倒计时）→ 静态文案「播完本曲」
/// - [SleepTimerMode.countdown] → 逐秒剩余时间；notifier 尚未落地时为 null，
///   同样收起（下一帧即显示真实倒计时）
Widget buildSleepTimerPill({
  required BuildContext context,
  required Duration? remaining,
  required SleepTimerMode mode,
  required SleepTimerPillStyle style,
  required VoidCallback onTap,
}) {
  final String label;
  switch (mode) {
    case SleepTimerMode.off:
      return const SizedBox.shrink();
    case SleepTimerMode.endOfTrack:
      label = '播完本曲';
    case SleepTimerMode.countdown:
      if (remaining == null) return const SizedBox.shrink();
      label = formatSleepTimerRemaining(remaining);
  }
  final textTheme = Theme.of(context).textTheme;
  return Material(
    color: style.backgroundColor,
    shape: const StadiumBorder(),
    child: InkWell(
      onTap: onTap,
      customBorder: const StadiumBorder(),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.timer_outlined, size: 14, color: style.foregroundColor),
            const SizedBox(width: 4),
            Text(
              label,
              style: textTheme.labelMedium?.copyWith(
                color: style.foregroundColor,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// 弹出「定时关闭」面板：1–90 分钟连续滑杆（无节点）+
/// 「定时结束后播完当前歌曲」+「关闭定时」。
void showSleepTimerSheet({
  required BuildContext context,
  required PlayerProvider player,
}) {
  final rootContext = context;
  // 初始值：已有定时时显示剩余分钟数（clamp 到滑杆范围），否则默认 30
  final initialMinutes = (player.sleepTimerRemaining?.inMinutes ?? 30).clamp(
    1,
    90,
  );
  showM3EModalBottomSheet(
    context: rootContext,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheetCtx) {
      // 拖动中的临时值必须声明在 StatefulBuilder 之外：
      // builder 重跑会重建局部变量，声明在内部会导致拖动值被重置
      double minutes = initialMinutes.toDouble();
      return SafeArea(
        child: ListenableBuilder(
          listenable: player,
          builder: (context, _) {
            final stopAfterCurrentTrack = player.stopAfterTimerEnds;
            return StatefulBuilder(
              builder: (context, setSheetState) {
                return Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        '定时关闭',
                        textAlign: TextAlign.center,
                        style: Theme.of(rootContext).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '${minutes.round()} 分钟',
                        textAlign: TextAlign.center,
                        style: Theme.of(rootContext).textTheme.headlineSmall
                            ?.copyWith(
                              color: Theme.of(rootContext).colorScheme.primary,
                              fontWeight: FontWeight.bold,
                            ),
                      ),
                      M3ESlider(
                        value: minutes,
                        min: 1,
                        max: 90,
                        onChanged: (v) => setSheetState(() => minutes = v),
                        onChangeEnd: (v) {
                          final d = Duration(minutes: v.round().clamp(1, 90));
                          player.setSleepTimer(d);
                          showToast(
                            '将在 ${d.inMinutes} 分钟后自动暂停',
                            long: true,
                          );
                        },
                      ),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            '1 分钟',
                            style: Theme.of(rootContext).textTheme.labelSmall
                                ?.copyWith(
                                  color: Theme.of(
                                    rootContext,
                                  ).colorScheme.onSurfaceVariant,
                                ),
                          ),
                          Text(
                            '90 分钟',
                            style: Theme.of(rootContext).textTheme.labelSmall
                                ?.copyWith(
                                  color: Theme.of(
                                    rootContext,
                                  ).colorScheme.onSurfaceVariant,
                                ),
                          ),
                        ],
                      ),
                      // 「定时结束后播完当前歌曲」开关：开启后定时到点不打断
                      // 播放，等当前正在播的这首自然播完再暂停；偏好到点后保留。
                      SwitchListTile(
                        secondary: const Icon(Icons.music_note_outlined),
                        title: const Text('定时结束后播完当前歌曲'),
                        value: stopAfterCurrentTrack,
                        onChanged: (next) {
                          player.setStopAfterCurrentTrack(next);
                          showToast(
                            next
                                ? '定时结束后将播完当前歌曲再暂停'
                                : '已取消「定时结束后播完当前歌曲」',
                            long: true,
                          );
                        },
                      ),
                      ListTile(
                        leading: const Icon(Icons.cancel_outlined),
                        title: const Text('关闭定时'),
                        onTap: () {
                          player.setSleepTimer(null);
                          Navigator.pop(sheetCtx);
                        },
                      ),
                    ],
                  ),
                );
              },
            );
          },
        ),
      );
    },
  );
}
