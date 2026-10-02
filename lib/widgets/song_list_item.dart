import 'package:m3e_core/m3e_core.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../core/services/lyrico_editor.dart';
import '../core/utils/app_toast.dart';
import '../data/models/song.dart';
import '../modules/player/comments_view.dart';
import '../modules/player/mv_player_page.dart';
import '../providers/favorites_provider.dart';
import '../providers/local_favorites_provider.dart';
import '../providers/player_provider.dart';
import 'add_to_playlist_dialog.dart';
import 'playing_spectrum_indicator.dart';
import 'smart_artwork_image.dart';
import 'song_menu_header.dart';

/// 歌曲行右侧操作区的呈现策略。
///
/// 不同场景只改变尾部操作，不改变歌曲行整体的视觉结构，从而保持跨页面一致性。
/// 用明确的枚举而非堆叠多个零散布尔参数（见改版计划三）。
enum SongTrailingActions {
  /// 默认完整操作：时长（受 [SongListItem.showDuration] 控制）+ 收藏 + 更多菜单。
  full,

  /// 每日推荐：右侧仅收藏按钮，不显示时长与更多菜单。
  favoriteOnly,

  /// 搜索结果：MV + 详情（三个点，收藏并入详情面板），不显示时长与独立收藏按钮。
  /// MV 在前、三个点在最右；云盘歌曲不显示不可用的 MV 按钮。
  detailAndMv,
}

class SongListItem extends StatelessWidget {
  /// 可选扩展：歌曲更多菜单的额外条目（默认关闭，由私有构建注入）。
  /// 返回的 Widget 追加在菜单底部（「下一首播放」之前）。
  static List<Widget> Function(BuildContext context, Song song)?
      extraMenuTilesBuilder;

  final Song song;
  final VoidCallback? onTap;
  final VoidCallback? onMoreTap;
  final bool showDuration;
  final bool forceFavorited;

  /// 右侧操作区呈现策略，默认完整操作（见 [SongTrailingActions]）。
  final SongTrailingActions trailingActions;

  /// 可选副标题覆盖：非空时替换默认的「歌手 - 专辑」行
  /// （如歌词搜索结果用于显示命中的歌词片段）。
  final Widget? subtitleOverride;

  /// 多选模式：显示圆形复选框替代封面，点击切换选中而非播放。
  final bool isSelectMode;
  final bool isSelected;
  final VoidCallback? onLongPress;
  final VoidCallback? onSelectToggle;

  const SongListItem({
    super.key,
    required this.song,
    this.onTap,
    this.onMoreTap,
    this.showDuration = true,
    this.forceFavorited = false,
    this.trailingActions = SongTrailingActions.full,
    this.subtitleOverride,
    this.isSelectMode = false,
    this.isSelected = false,
    this.onLongPress,
    this.onSelectToggle,
  });

  void _showMoreMenu(BuildContext context) {
    showM3EModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 头部：圆角矩形封面 + 歌名/歌手/专辑（原 music_note ListTile）
            SongMenuHeader(song: song),
            const Divider(height: 1),
            // 收藏 / 取消收藏：详情面板内实时状态。搜索结果的收藏入口即在此
            // （列表行不再放独立收藏按钮），其他场景作为附加操作也无害。
            Consumer2<FavoritesProvider, LocalFavoritesProvider>(
              builder: (ctx2, favorites, localFavorites, _) {
                final favorited = forceFavorited
                    ? true
                    : (song.isOnline
                        ? favorites.isFavorite(song.id)
                        : localFavorites.isFavorite(song.id));
                final cs = Theme.of(ctx2).colorScheme;
                return ListTile(
                  leading: Icon(
                    favorited ? Icons.favorite : Icons.favorite_border,
                    color: favorited ? cs.error : null,
                  ),
                  title: Text(favorited ? '取消收藏' : '收藏'),
                  onTap: () => song.isOnline
                      ? favorites.toggleFavorite(song)
                      : localFavorites.toggleFavorite(song.id),
                );
              },
            ),
            // 本地音乐（有本地文件路径）：提供 Lyrico 外部编辑入口（公开功能）
            if (!song.isOnline && song.localPath != null)
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: const Text('编辑歌曲信息'),
                onTap: () async {
                  Navigator.pop(ctx);
                  final r = await LyricoEditor.launchLyricoEdit(song.localPath!);
                  if (!r.installed) {
                    showToast('未安装 Lyrico，请先安装后再编辑', long: true);
                  } else if (!r.launched) {
                    showToast('无法打开 Lyrico 编辑', long: true);
                  }
                },
              ),
            if (song.isOnline)
              ListTile(
                leading: const Icon(Icons.music_video_outlined),
                title: const Text('查看 MV'),
                onTap: () {
                  Navigator.pop(ctx);
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => MvPlayerPage(song: song)),
                  );
                },
              ),
            // 可选扩展：私有构建注入的额外菜单条目（默认无）
            ...?SongListItem.extraMenuTilesBuilder?.call(ctx, song),
            ListTile(
              // 与紧邻的「下一首播放」(playlist_add) 区分图标，避免同图标相邻
              leading: const Icon(Icons.add_to_queue_outlined),
              title: const Text('添加到歌单'),
              onTap: () {
                Navigator.pop(ctx);
                showAddToPlaylistDialog(context, song);
              },
            ),
            ListTile(
              leading: const Icon(Icons.playlist_add),
              title: const Text('下一首播放'),
              onTap: () {
                Navigator.pop(ctx);
                final player = context.read<PlayerProvider>();
                player.insertAfterCurrent([song]);
                showToast('已加入下一首', long: true);
              },
            ),
            // 在线歌曲恒提供；本地歌曲由「关闭本地音乐评论区」开关决定
            if (context.read<PlayerProvider>().showsCommentsFor(song))
              ListTile(
                leading: const Icon(Icons.comment_outlined),
                title: const Text('看评论'),
                onTap: () {
                  Navigator.pop(ctx);
                  showSongCommentsSheet(context, song);
                },
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // 列表行只订阅实际影响自身外观的状态，避免播放器或收藏集合的
    // 无关通知让所有可见歌曲行一起重建。
    final playbackRowState = context.select<PlayerProvider, (bool, bool)>((
      provider,
    ) {
      final isCurrent = provider.currentSong?.id == song.id;
      // 非当前行不展示播放动画，不需要跟随全局播放/暂停状态重建。
      return (isCurrent, isCurrent && provider.isPlaying);
    });
    final isCurrentSong = playbackRowState.$1;
    final isPlaying = playbackRowState.$2;
    final isFavorited = forceFavorited
        ? true
        : (song.isOnline
              ? context.select<FavoritesProvider, bool>(
                  (provider) => provider.isFavorite(song.id),
                )
              : context.select<LocalFavoritesProvider, bool>(
                  (provider) => provider.isFavorite(song.id),
                ));
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    const imgSize = 52.0; // 正方形封面，不被 ListTile 压缩

    return InkWell(
      onTap: isSelectMode ? onSelectToggle : onTap,
      onLongPress: onLongPress,
      child: Container(
        color: isSelectMode && isSelected
            ? colorScheme.primaryContainer.withValues(alpha: 0.3)
            : Colors.transparent,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Row(
          children: [
            // 多选模式：圆形复选框；普通模式：封面图
            if (isSelectMode)
              _buildCheckbox(colorScheme, imgSize)
            else
              // 封面图：智能选择 Image.network（在线/content://）或 LocalArtworkImage（文件路径）
              SmartArtworkImage(
                artworkUri: song.artworkUri,
                fallbackFilePath: song.localPath,
                songId: song.id,
                size: imgSize,
                borderRadius: 8,
              ),
            const SizedBox(width: 12),

            // 标题 + 副标题
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    song.displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w500,
                      color: isCurrentSong ? colorScheme.primary : null,
                    ),
                  ),
                  const SizedBox(height: 2),
                  subtitleOverride ??
                      Text(
                        '${song.artist} - ${song.album}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.labelSmall?.copyWith(
                          color: isCurrentSong
                              ? colorScheme.primary.withValues(alpha: 0.7)
                              : colorScheme.onSurfaceVariant,
                        ),
                      ),
                ],
              ),
            ),

            // 右侧操作区：多选模式下不显示
            if (!isSelectMode)
              Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  if (isCurrentSong)
                    Padding(
                      padding: const EdgeInsets.only(right: 2),
                      // 频谱动画标识：3 根粒度柱 sin 波动
                      // 暂停时 isPlaying=false → ticker 停止，保留最后一帧
                      // 继续播放时 isPlaying=true → ticker 恢复，动画继续
                      child: PlayingSpectrumIndicator(
                        color: colorScheme.primary,
                        size: 14,
                        isPlaying: isPlaying,
                      ),
                    ),
                  ..._buildTrailingActions(
                    context,
                    colorScheme,
                    textTheme,
                    isFavorited,
                    context.read<FavoritesProvider>(),
                    context.read<LocalFavoritesProvider>(),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  /// 按 [trailingActions] 策略构建右侧操作。不同页面只改变尾部操作，
  /// 不改变歌曲行整体结构，保持跨页面一致性。
  List<Widget> _buildTrailingActions(
    BuildContext context,
    ColorScheme colorScheme,
    TextTheme textTheme,
    bool isFavorited,
    FavoritesProvider favoritesProvider,
    LocalFavoritesProvider localFavoritesProvider,
  ) {
    switch (trailingActions) {
      case SongTrailingActions.favoriteOnly:
        return [
          _favoriteButton(
            colorScheme,
            isFavorited,
            favoritesProvider,
            localFavoritesProvider,
          ),
        ];
      case SongTrailingActions.detailAndMv:
        return [
          // MV 在前，详情（三个点）在最右：与「更多菜单」全局一致用 more_vert，
          // 且与 MV 按钮顺序对调（见改版计划补充一）。
          // 云盘歌曲无 MV；仅在线非云盘歌曲显示 MV 入口。
          if (song.isOnline && !song.isCloud)
            _iconAction(
              colorScheme,
              Icons.music_video_outlined,
              () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => MvPlayerPage(song: song)),
              ),
            ),
          _iconAction(
            colorScheme,
            Icons.more_vert,
            () => _showMoreMenu(context),
          ),
        ];
      case SongTrailingActions.full:
        return [
          if (showDuration)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Text(song.displayDuration, style: textTheme.labelSmall),
            ),
          _favoriteButton(
            colorScheme,
            isFavorited,
            favoritesProvider,
            localFavoritesProvider,
          ),
          _iconAction(colorScheme, Icons.more_vert, () => _showMoreMenu(context)),
        ];
    }
  }

  Widget _favoriteButton(
    ColorScheme colorScheme,
    bool isFavorited,
    FavoritesProvider favoritesProvider,
    LocalFavoritesProvider localFavoritesProvider,
  ) {
    return GestureDetector(
      onTap: () => song.isOnline
          ? favoritesProvider.toggleFavorite(song)
          : localFavoritesProvider.toggleFavorite(song.id),
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 4),
        child: Icon(
          isFavorited ? Icons.favorite : Icons.favorite_border,
          size: 18,
          color: isFavorited ? colorScheme.error : colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  Widget _iconAction(
    ColorScheme colorScheme,
    IconData icon,
    VoidCallback onTap,
  ) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
        child: Icon(icon, size: 18, color: colorScheme.onSurfaceVariant),
      ),
    );
  }

  /// 多选模式下的圆形复选框，与封面同等大小。
  Widget _buildCheckbox(ColorScheme colorScheme, double size) {
    return SizedBox(
      width: size,
      height: size,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 150),
        child: isSelected
            ? Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: colorScheme.primary,
                ),
                child: Icon(
                  Icons.check,
                  color: colorScheme.onPrimary,
                  size: 28,
                ),
              )
            : Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: colorScheme.outline.withValues(alpha: 0.5),
                    width: 2,
                  ),
                ),
              ),
      ),
    );
  }
}
