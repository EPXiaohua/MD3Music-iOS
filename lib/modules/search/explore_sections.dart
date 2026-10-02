import 'package:cached_network_image/cached_network_image.dart';
import 'package:material_ui/material_ui.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:provider/provider.dart';

import '../../data/models/album.dart';
import '../../core/layout/responsive_layout.dart';
import '../../core/theme/app_dimens.dart';
import '../../providers/kugou_provider.dart';
import '../../providers/player_provider.dart';
import '../../services/kugou_api/kugou_models.dart';
import '../../widgets/album_card.dart';
import '../../widgets/pinchable_grid_view.dart';
import '../../widgets/song_list_item.dart';
import '../album/album_detail_page.dart';
import '../charts/charts_page.dart';
import '../player/secondary_mini_player.dart';
import '../playlist/playlist_page.dart';

/// 音乐探索内容模块（改版计划一：从发现页迁移到搜索空白态）。
///
/// 每个模块统一「标题 + 横向滑动内容带」结构，视觉密度参照推荐内容，
/// 不复制发现页原有的折叠状态。复用 [KugouProvider] 已有数据与缓存，
/// 避免发现页、搜索页重复请求：仅在对应数据为空时补一次请求。
class MusicExploreSections extends StatefulWidget {
  const MusicExploreSections({super.key});

  @override
  State<MusicExploreSections> createState() => _MusicExploreSectionsState();
}

class _MusicExploreSectionsState extends State<MusicExploreSections> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _ensureLoaded());
  }

  /// 仅在数据缺失时补拉；forceRefresh=false 命中 5 分钟缓存即不重复请求，
  /// 与发现页共享同一份 KugouProvider 数据。
  void _ensureLoaded() {
    if (!mounted) return;
    final kugou = context.read<KugouProvider>();
    if (kugou.themePlaylistData.isEmpty) kugou.getThemePlaylist();
    if (kugou.sceneData == null) kugou.getSceneMusic();
    if (kugou.playlistList.isEmpty) kugou.getPlaylist();
    if (kugou.rankList == null) kugou.getRankList();
    if (kugou.topAlbums.isEmpty) kugou.getTopAlbum();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildThemeSection(),
        _buildSceneSection(),
        _buildPlaylistSection(),
        _buildRankSection(),
        _buildNewAlbumSection(),
        const Gap(AppSpacing.sm),
      ],
    );
  }
  /// 主题歌单：横滑方卡（130 宽），展示态，无「更多」入口。
  Widget _buildThemeSection() {
    return Selector<KugouProvider, List<KugouThemeInfo>>(
      selector: (_, kugou) => kugou.themePlaylistData,
      builder: (context, themes, _) {
        if (themes.isEmpty) return const SizedBox.shrink();
        final cs = Theme.of(context).colorScheme;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _SectionHeader(title: '主题歌单'),
            SizedBox(
              height: 166,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
                itemCount: themes.length,
                itemBuilder: (context, i) => Padding(
                  padding: const EdgeInsets.only(right: AppSpacing.md),
                  child: SizedBox(
                    width: 130,
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius: AppRadius.lgAll,
                        color: cs.surfaceContainerLow,
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          AspectRatio(
                            aspectRatio: 1,
                            child: CachedNetworkImage(
                              imageUrl: themes[i].coverUrl ?? '',
                              memCacheWidth: 390,
                              memCacheHeight: 390,
                              fit: BoxFit.cover,
                              placeholder: (_, _) => _coverPlaceholder(cs),
                              errorWidget: (_, _, _) => _coverPlaceholder(cs),
                            ),
                          ),
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 6,
                              ),
                              child: Align(
                                alignment: Alignment.centerLeft,
                                child: Text(
                                  themes[i].name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context)
                                      .textTheme
                                      .titleSmall
                                      ?.copyWith(
                                        fontWeight: FontWeight.w500,
                                        color: cs.onSurface,
                                      ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  static Widget _coverPlaceholder(ColorScheme cs) => Container(
        color: cs.surfaceContainerHighest,
        child: Icon(Icons.music_note, color: cs.onSurfaceVariant),
      );
  /// 场景音乐：一行 chip 流（展示态，无点击目标）。
  Widget _buildSceneSection() {
    return Selector<KugouProvider, Map<String, dynamic>?>(
      selector: (_, kugou) => kugou.sceneData,
      builder: (context, sceneData, _) {
        if (sceneData == null) return const SizedBox.shrink();
        final cs = Theme.of(context).colorScheme;
        final data = sceneData['data'] as Map<String, dynamic>? ?? sceneData;
        final list = data['list'] ?? data['info'] ?? [];
        if (list is! List || list.isEmpty) return const SizedBox.shrink();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _SectionHeader(title: '场景音乐'),
            SizedBox(
              height: 44,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
                itemCount: list.length,
                itemBuilder: (context, i) {
                  final item = list[i] as Map<String, dynamic>;
                  return Padding(
                    padding: const EdgeInsets.only(right: AppSpacing.sm),
                    child: Chip(
                      label: Text(item['name']?.toString() ?? ''),
                      labelStyle: Theme.of(context)
                          .textTheme
                          .labelLarge
                          ?.copyWith(color: cs.onSurfaceVariant),
                      backgroundColor: cs.surfaceContainerLow,
                      side: BorderSide(color: cs.outlineVariant),
                    ),
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }

  /// 热门歌单：2 列小封面网格（封面在左、标题在右，与每日推荐布局相似），
  /// 最多 6 个，点击进歌单详情，「›」进浏览页。
  Widget _buildPlaylistSection() {
    return Selector<KugouProvider, List<KugouPlaylistBrief>>(
      selector: (_, kugou) => kugou.playlistList,
      builder: (context, plist, _) {
        if (plist.isEmpty) return const SizedBox.shrink();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _SectionHeader(
              title: '热门歌单',
              onMore: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const PlaylistBrowsePage()),
              ),
            ),
            _CompactAlbumGrid(
              albums: [
                for (final p in plist)
                  Album(
                    id: p.id,
                    name: p.name,
                    artist: '',
                    artworkUri: p.coverUrl,
                    songCount: p.songCount,
                  ),
              ],
              onTap: (i) => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => PlaylistPage(playlist: plist[i].toPlaylist()),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  /// 排行榜：2 列小封面网格，最多 6 个，点击进榜单歌曲页，「›」进排行榜页。
  Widget _buildRankSection() {
    return Selector<KugouProvider, KugouRankList?>(
      selector: (_, kugou) => kugou.rankList,
      builder: (context, rankList, _) {
        final ranks = rankList?.ranks ?? const <KugouRank>[];
        if (ranks.isEmpty) return const SizedBox.shrink();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _SectionHeader(
              title: '排行榜',
              onMore: () => Navigator.of(context)
                  .push(MaterialPageRoute(builder: (_) => const ChartsPage())),
            ),
            _CompactAlbumGrid(
              albums: [for (final r in ranks) r.toAlbum()],
              onTap: (i) => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => RankDetailPage(
                    rankId: ranks[i].id,
                    rankName: ranks[i].name,
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  /// 新碟上架：2 列小封面网格，最多 6 个，点击进专辑详情，「›」进浏览页。
  Widget _buildNewAlbumSection() {
    return Selector<KugouProvider, List<KugouAlbumBrief>>(
      selector: (_, kugou) => kugou.topAlbums,
      builder: (context, albums, _) {
        if (albums.isEmpty) return const SizedBox.shrink();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _SectionHeader(
              title: '新碟上架',
              onMore: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const NewAlbumBrowsePage()),
              ),
            ),
            _CompactAlbumGrid(
              albums: [for (final a in albums) a.toAlbum()],
              onTap: (i) => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => AlbumDetailPage(album: albums[i].toAlbum()),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// 新碟上架浏览页（从发现页迁移）。
class NewAlbumBrowsePage extends StatefulWidget {
  const NewAlbumBrowsePage({super.key});
  @override
  State<NewAlbumBrowsePage> createState() => _NewAlbumBrowsePageState();
}

class _NewAlbumBrowsePageState extends State<NewAlbumBrowsePage> {
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await context.read<KugouProvider>().getTopAlbum();
      if (mounted) setState(() => _isLoading = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('新碟上架')),
      body: _isLoading
          ? const Center(child: M3ELoadingIndicator())
          : Selector<KugouProvider, List<KugouAlbumBrief>>(
              selector: (_, kugou) => kugou.topAlbums,
              builder: (context, list, _) {
                if (list.isEmpty) return const Center(child: Text('暂无数据'));
                return PinchableGridView(
                  padding: EdgeInsets.fromLTRB(
                    AppSpacing.lg, AppSpacing.lg, AppSpacing.lg,
                    AppSpacing.lg + MediaQuery.paddingOf(context).bottom,
                  ),
                  childAspectRatio: 0.8,
                  spacing: 12,
                  itemCount: list.length,
                  itemBuilder: (context, i) => AlbumCard(
                    album: list[i].toAlbum(),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) =>
                            AlbumDetailPage(album: list[i].toAlbum()),
                      ),
                    ),
                  ),
                );
              },
            ),
    );
  }
}

/// 排行榜歌曲页（从发现页迁移）。
class RankDetailPage extends StatefulWidget {
  final String rankId;
  final String rankName;
  const RankDetailPage({super.key, required this.rankId, required this.rankName});
  @override
  State<RankDetailPage> createState() => _RankDetailPageState();
}

class _RankDetailPageState extends State<RankDetailPage> {
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await context.read<KugouProvider>().getRankSongs(rankId: widget.rankId);
      if (mounted) setState(() => _isLoading = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.rankName)),
      body: SecondaryMiniPlayerHost(
        child: _isLoading
          ? const Center(child: M3ELoadingIndicator())
          : Selector<KugouProvider, List<KugouSongDetail>>(
              selector: (_, kugou) => kugou.rankSongs,
              builder: (context, songs, _) {
                if (songs.isEmpty) {
                  return Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Text('暂无数据'),
                        ElevatedButton(
                          onPressed: () async {
                            setState(() => _isLoading = true);
                            await context.read<KugouProvider>().getRankSongs(
                              rankId: widget.rankId,
                              forceRefresh: true,
                            );
                            if (mounted) setState(() => _isLoading = false);
                          },
                          child: const Text('重试'),
                        ),
                      ],
                    ),
                  );
                }
                return ListView.builder(
                  padding: EdgeInsets.fromLTRB(
                    AppSpacing.lg, AppSpacing.lg, AppSpacing.lg,
                    AppSpacing.lg + MediaQuery.paddingOf(context).bottom,
                  ),
                  itemCount: songs.length,
                  itemBuilder: (context, i) {
                    final song = songs[i].toSong();
                    return SongListItem(
                      song: song,
                      onTap: () =>
                          context.read<PlayerProvider>().playOnlinePlaylist(
                            songs.map((e) => e.toSong()).toList(),
                            i,
                          ),
                      onMoreTap: () {},
                    );
                  },
                );
              },
            ),
      ),
    );
  }
}


/// 内容模块标题行：标题 + 可选「›」更多入口。
class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, this.onMore});

  final String title;
  final VoidCallback? onMore;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.lg, AppSpacing.sm, AppSpacing.sm),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w600),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (onMore != null)
            IconButton(
              onPressed: onMore,
              icon: const Icon(Icons.chevron_right),
            ),
        ],
      ),
    );
  }
}

/// 2 列小封面网格：每格「小方封面（左）+ 标题/曲数（右）」，与每日推荐的
/// 列表项形态一致，两两并排。最多展示 [maxItems] 个，其余在标题「›」里查看。
class _CompactAlbumGrid extends StatelessWidget {
  const _CompactAlbumGrid({
    required this.albums,
    required this.onTap,
    this.maxItems = 6,
  });

  final List<Album> albums;
  final ValueChanged<int> onTap;
  final int maxItems;

  @override
  Widget build(BuildContext context) {
    final count = albums.length < maxItems ? albums.length : maxItems;
    // 计划 4.7：按面板局部宽度定列数——桌面宽面板多列，手机仍两列。
    return LayoutBuilder(
      builder: (context, c) {
        final columns = isDesktopLayout(context)
            ? gridColumnsForWidth(c.maxWidth,
                targetExtent: 280, min: 2, max: 4)
            : 2;
        final rows = <Widget>[];
        for (var i = 0; i < count; i += columns) {
          final cells = <Widget>[];
          for (var j = 0; j < columns; j++) {
            final idx = i + j;
            if (j > 0) cells.add(const Gap(AppSpacing.md));
            cells.add(
              Expanded(
                child: idx < count
                    ? _cell(context, idx)
                    : const SizedBox.shrink(),
              ),
            );
          }
          rows.add(
            Padding(
              padding: const EdgeInsets.fromLTRB(AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.sm),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: cells,
              ),
            ),
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: rows,
        );
      },
    );
  }

  Widget _cell(BuildContext context, int index) {
    final cs = Theme.of(context).colorScheme;
    final album = albums[index];
    return InkWell(
      onTap: () => onTap(index),
      borderRadius: AppRadius.mdAll,
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xs),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: AppRadius.smAll,
              child: SizedBox(
                width: 52,
                height: 52,
                child: CachedNetworkImage(
                  imageUrl: album.artworkUri ?? '',
                  memCacheWidth: 156,
                  memCacheHeight: 156,
                  fit: BoxFit.cover,
                  placeholder: (_, _) =>
                      _MusicExploreSectionsState._coverPlaceholder(cs),
                  errorWidget: (_, _, _) =>
                      _MusicExploreSectionsState._coverPlaceholder(cs),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                album.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w500,
                      color: cs.onSurface,
                    ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 热门歌单浏览页（从发现页迁移）。
class PlaylistBrowsePage extends StatefulWidget {
  const PlaylistBrowsePage({super.key});
  @override
  State<PlaylistBrowsePage> createState() => _PlaylistBrowsePageState();
}

class _PlaylistBrowsePageState extends State<PlaylistBrowsePage> {
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await context.read<KugouProvider>().getPlaylist();
      if (mounted) setState(() => _isLoading = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('热门歌单')),
      body: _isLoading
          ? const Center(child: M3ELoadingIndicator())
          : Selector<KugouProvider, List<KugouPlaylistBrief>>(
              selector: (_, kugou) => kugou.playlistList,
              builder: (context, list, _) {
                if (list.isEmpty) return const Center(child: Text('暂无数据'));
                return PinchableGridView(
                  padding: EdgeInsets.fromLTRB(
                    AppSpacing.lg, AppSpacing.lg, AppSpacing.lg,
                    AppSpacing.lg + MediaQuery.paddingOf(context).bottom,
                  ),
                  childAspectRatio: 0.8,
                  spacing: 12,
                  itemCount: list.length,
                  itemBuilder: (context, i) => AlbumCard(
                    album: Album(
                      id: list[i].id,
                      name: list[i].name,
                      artist: '',
                      artworkUri: list[i].coverUrl,
                      songCount: list[i].songCount,
                    ),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) =>
                            PlaylistPage(playlist: list[i].toPlaylist()),
                      ),
                    ),
                  ),
                );
              },
            ),
    );
  }
}

