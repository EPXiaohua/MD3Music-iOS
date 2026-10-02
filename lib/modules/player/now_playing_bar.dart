import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../core/utils/app_haptics.dart';
import '../../providers/favorites_provider.dart';
import '../../providers/player_provider.dart';
import '../../widgets/smart_artwork_image.dart';
import 'full_player_route.dart';

/// 全宽底部播放栏（桌面音乐软件式，见横屏平板重设计计划 4.6）。
///
/// 横跨侧栏 + 内容区，复用 [PlayerProvider]。布局：
/// - 左：封面 + 标题/歌手（点击进完整播放页）；
/// - 中：上一首 / 播放暂停 / 下一首 + 进度条（可拖动 seek）；
/// - 右：收藏 / 播放模式（循环·随机）。
///
/// 桌面布局下由 [DesktopShell] 渲染，同时抑制底部全局 [MiniPlayer] 与二级
/// 悬浮播放器，避免三套播放器并存割裂。无正在播放歌曲时整栏收起。
class NowPlayingBar extends StatelessWidget {
  const NowPlayingBar({super.key});

  static const double _kHeight = 72.0;

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerProvider>();
    final song = player.currentSong;
    final cs = Theme.of(context).colorScheme;

    // 完整播放页展开时整栏淡出（与 MiniPlayer 同一 playerExpansion 规则）。
    return ValueListenableBuilder<double>(
      valueListenable: playerExpansion,
      builder: (context, exp, child) {
        final opacity = (1.0 - exp).clamp(0.0, 1.0);
        return IgnorePointer(ignoring: exp > 0.5, child: Opacity(opacity: opacity, child: child));
      },
      child: AnimatedSize(
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOutCubic,
        alignment: Alignment.bottomCenter,
        child: song == null
            ? const SizedBox(width: double.infinity)
            : _buildBar(context, player, song, cs),
      ),
    );
  }

  Widget _buildBar(
    BuildContext context,
    PlayerProvider player,
    dynamic song,
    ColorScheme cs,
  ) {
    return Material(
      color: cs.surfaceContainerHigh,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Divider(height: 1, thickness: 1, color: cs.outlineVariant),
          SizedBox(
            height: _kHeight,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  // 左：封面 + 标题/歌手（点击进完整播放页）
                  Expanded(
                    child: _NowPlayingInfo(song: song),
                  ),
                  // 中：传输控制 + 进度条
                  Expanded(
                    flex: 2,
                    child: _NowPlayingControls(player: player),
                  ),
                  // 右：收藏 + 播放模式
                  Expanded(
                    child: _NowPlayingExtras(player: player, song: song),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _NowPlayingInfo extends StatelessWidget {
  const _NowPlayingInfo({required this.song});
  final dynamic song;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () {
        AppHaptics.click();
        openFullPlayer(context);
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: SizedBox(
                width: 48,
                height: 48,
                child: SmartArtworkImage(
                  artworkUri: song.artworkUri,
                  fallbackFilePath: song.localPath,
                  songId: song.id,
                  size: 48,
                  borderRadius: 6,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    song.displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  Text(
                    song.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: cs.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NowPlayingControls extends StatelessWidget {
  const _NowPlayingControls({required this.player});
  final PlayerProvider player;

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    final h = d.inHours;
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton(
              icon: const Icon(Icons.skip_previous),
              tooltip: '上一首',
              onPressed: () {
                AppHaptics.click();
                player.previous();
              },
            ),
            const SizedBox(width: 4),
            IconButton.filled(
              icon: Icon(player.isPlaying ? Icons.pause : Icons.play_arrow),
              tooltip: player.isPlaying ? '暂停' : '播放',
              onPressed: () {
                AppHaptics.click();
                if (player.isPlaying) {
                  player.pause();
                } else {
                  player.resume();
                }
              },
            ),
            const SizedBox(width: 4),
            IconButton(
              icon: const Icon(Icons.skip_next),
              tooltip: '下一首',
              onPressed: () {
                AppHaptics.click();
                player.next();
              },
            ),
          ],
        ),
        // 进度条：只订阅 positionNotifier，避免整栏随进度高频重建。
        ValueListenableBuilder<Duration>(
          valueListenable: player.positionNotifier,
          builder: (context, pos, _) {
            final dur = player.duration ?? Duration.zero;
            final maxMs = dur.inMilliseconds.toDouble();
            final value = maxMs > 0
                ? pos.inMilliseconds.clamp(0, dur.inMilliseconds).toDouble()
                : 0.0;
            return Row(
              children: [
                SizedBox(
                  width: 44,
                  child: Text(
                    _fmt(pos),
                    textAlign: TextAlign.end,
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                ),
                Expanded(
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 3,
                      thumbShape:
                          const RoundSliderThumbShape(enabledThumbRadius: 6),
                      overlayShape:
                          const RoundSliderOverlayShape(overlayRadius: 12),
                    ),
                    child: Slider(
                      value: maxMs > 0 ? value : 0.0,
                      max: maxMs > 0 ? maxMs : 1.0,
                      onChanged: maxMs > 0
                          ? (v) => player
                              .seek(Duration(milliseconds: v.round()), forceNotify: true)
                          : null,
                    ),
                  ),
                ),
                SizedBox(
                  width: 44,
                  child: Text(
                    _fmt(dur),
                    style: Theme.of(context)
                        .textTheme
                        .labelSmall
                        ?.copyWith(color: cs.onSurfaceVariant),
                  ),
                ),
              ],
            );
          },
        ),
      ],
    );
  }
}

class _NowPlayingExtras extends StatelessWidget {
  const _NowPlayingExtras({required this.player, required this.song});
  final PlayerProvider player;
  final dynamic song;

  IconData _loopIcon() {
    if (player.shuffleEnabled) return Icons.shuffle;
    switch (player.loopMode) {
      case AppLoopMode.one:
        return Icons.repeat_one;
      case AppLoopMode.all:
        return Icons.repeat_on;
      case AppLoopMode.off:
        return Icons.repeat;
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final favorites = context.watch<FavoritesProvider>();
    final isFav = favorites.isFavorite(song.id);
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        IconButton(
          tooltip: isFav ? '取消收藏' : '收藏',
          icon: Icon(
            isFav ? Icons.favorite : Icons.favorite_border,
            color: isFav ? cs.primary : null,
          ),
          onPressed: () {
            AppHaptics.click();
            favorites.toggleFavorite(song);
          },
        ),
        IconButton(
          tooltip: '播放模式',
          icon: Icon(
            _loopIcon(),
            color: player.shuffleEnabled || player.loopMode != AppLoopMode.off
                ? cs.primary
                : null,
          ),
          onPressed: () {
            AppHaptics.click();
            player.cyclePlayMode();
          },
        ),
      ],
    );
  }
}
