import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:m3e_core/m3e_core.dart';
import '../../core/theme/app_dimens.dart';
import '../../widgets/md3_pull_to_refresh.dart';

import '../../providers/kugou_provider.dart';
import '../../providers/player_provider.dart';
import '../../services/kugou_api/kugou_models.dart';
import '../../widgets/scroll_aware_app_bar.dart';
import '../../widgets/song_list_item.dart';
import 'home_discover_refill.dart';
import '../personal_fm/personal_fm_section.dart';
import '../player/secondary_mini_player.dart';
import '../recognition/song_recognition_page.dart';
import '../search/search_page.dart';

/// 顶栏图标按钮（搜索 / 识曲）的尺寸：36 而不是 MD3 默认的 48，让两个图标之间
/// 由 24dp 收到 12dp；纵向仍保留 40dp 触达高度。
const double _kActionButtonWidth = 36.0;
const double _kActionButtonHeight = 40.0;

/// 补回按钮收窄的宽度，让最右那枚图标与屏幕边缘的距离保持不变。
const double _kActionTrailingGap = 6.0;

class DiscoverPage extends StatefulWidget {
  const DiscoverPage({super.key});

  @override
  State<DiscoverPage> createState() => _DiscoverPageState();
}

class _DiscoverPageState extends State<DiscoverPage> {
  static const String _kDiscoverLastDateKey = 'discover_last_date';

  // 每日推荐区块的折叠状态（true=折叠）。SharedPreferences 存"是否折叠"。
  //
  // 发现页现在只保留私人 FM + 每日推荐两块（主题歌单/场景音乐/热门歌单/排行榜/
  // 新碟上架已迁移到搜索空白态，见 MusicExploreSections）。私人 FM 没有标题行
  // （见 [PersonalFmSection]），卡片恒定展示、无折叠把手；因此只剩每日推荐可折叠。
  static const String _kCollapsedDaily = 'discover_collapsed_daily';

  // 刷歌推荐区块的折叠状态，键名与每日推荐同一套约定（前缀 + 分区），
  // 这样两块共用 [_toggleCollapse] 的「prefs 存的是否折叠」语义。
  static const String _kCollapsedHomeDiscover = 'discover_collapsed_home_discover';

  bool _isLoading = true;
  String? _error;

  bool _isDailyExpanded = true;
  bool _isHomeDiscoverExpanded = true;

  /// 顶栏渐变 ScrollController：与 ScrollAwareAppBar 共享，监听滚动 offset
  final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initIfNeeded();
      _loadCollapseStates();
    });
  }

  /// 从 SharedPreferences 恢复每日推荐 section 的折叠状态
  Future<void> _loadCollapseStates() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _isDailyExpanded = !(prefs.getBool(_kCollapsedDaily) ?? false);
      _isHomeDiscoverExpanded = !(prefs.getBool(_kCollapsedHomeDiscover) ?? false);
    });
  }

  /// 切换 section 展开/折叠并持久化
  Future<void> _toggleCollapse({
    required String prefKey,
    required bool currentlyExpanded,
    required ValueChanged<bool> apply,
  }) async {
    final next = !currentlyExpanded;
    setState(() => apply(next));
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(prefKey, !next);
  }

  /// 每天只自动加载一次：内存有数据且是同一天则跳过，否则拉取
  Future<void> _initIfNeeded() async {
    if (!mounted) return;
    final kugou = context.read<KugouProvider>();
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    final lastDate = prefs.getString(_kDiscoverLastDateKey);
    final today = _todayString();
    if (kugou.hasLoadedDiscoverData && lastDate == today) {
      if (mounted) setState(() => _isLoading = false);
      return;
    }
    if (lastDate != null && lastDate != today) {
      // 跨天：重置标志，让 _loadAllData 重新拉
      kugou.resetDiscoverLoadedFlag();
    }

    // 自动重试：首次启动时 Node.js 服务器可能尚未完全就绪
    int retryCount = 0;
    while (retryCount < 3) {
      await _loadAllData();
      if (!mounted) return;

      // 检查是否真的加载到了数据（发现页只剩每日推荐 + 私人 FM）
      if (kugou.recommendSongs.isNotEmpty ||
          kugou.personalFmSongs.isNotEmpty) {
        break; // 有数据了，退出重试
      }

      retryCount++;
      if (retryCount < 3 && mounted) {
        await Future.delayed(const Duration(seconds: 2));
      }
    }
  }

  String _todayString() {
    final d = DateTime.now();
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }

  /// 是否有任一发现分区数据就绪（渐进加载用）：任一就绪即退出整页转圈。
  /// 刷歌推荐（首页 /home/discover）也算一块：它进页面就能拿到首屏 4 首，
  /// 没有它的话只有每日推荐慢半拍时整个刷歌区会先空着。
  bool get _hasAnySectionData {
    final kugou = context.read<KugouProvider>();
    return kugou.recommendSongs.isNotEmpty ||
        kugou.personalFmSongs.isNotEmpty ||
        kugou.homeDiscoverSongs.isNotEmpty;
  }

  Future<void> _loadAllData() async {
    if (!mounted) return; // 页面已销毁则放弃，避免访问 context 触发 null check 崩溃
    final kugou = context.read<KugouProvider>();
    final hasExistingData = kugou.hasLoadedDiscoverData;
    // 私人 FM 不跟着刷新走。它背后是流式接口（`action=play`，「给我下一批」），
    // 每次请求返回的都是不同的一批歌，而发现页的 FM 卡片直接渲染列表第一首。
    // 跟着下拉刷新就会静默换掉卡上显示的、甚至正在播的那首歌：卡片与播放器
    // 脱钩（按钮翻回 ▶、收藏指向别的歌），而且刷新不传档位参数，服务端回落到
    // normal/0，用户停在「探索」「小众」时内容还会被换成「红心」档的。
    // 所以只在手上一首都没有时补一次，之后换歌只由用户自己触发
    // （切档位 / 完整 FM 页）。
    final needsPersonalFm = kugou.personalFmSongs.isEmpty;
    // 已有数据时直接展示，后台静默刷新
    if (!hasExistingData) {
      setState(() {
        _isLoading = true;
        _error = null;
      });
    }
    try {
      // 渐进加载：请求并行发起，每个分区完成后立即刷新一次。
      // 发现页只保留每日推荐 + 私人 FM 两块；主题歌单/场景音乐/热门歌单/
      // 排行榜/新碟上架已迁到搜索空白态（MusicExploreSections 按需拉取）。
      final reqs = <Future<void>>[
        kugou.getRecommendDaily(forceRefresh: hasExistingData),
        // 这里 forceRefresh 恒为 true 不是笔误：列表为空才会走到这一句，而空列表
        // 也会盖上新鲜时间戳（上一次请求成功但返回了空），不绕开 5 分钟 TTL 的话
        // 卡片会空着却「新鲜」，下拉也补不回来。
        if (needsPersonalFm) kugou.getPersonalFm(forceRefresh: true),
        // 刷歌推荐下拉只 forceRefresh、**不重置游标**：forceRefresh 在
        // getHomeDiscover 里的含义仅仅是绕过 5 分钟 TTL，游标（已消费条数）和
        // seen（已消费 hash，持久化在 HomeDiscoverProgressStore）都原样保留。
        // 刷歌的意义就是"每次点开/下拉都是没听过的"，重置游标等于把刚刷过的那
        // 几首原样端回来，用户会反复看见同一批歌，那还不如不放这个入口。
        kugou.getHomeDiscover(forceRefresh: hasExistingData),
      ];
      for (final f in reqs) {
        unawaited(f.then((_) {
          if (mounted) setState(() {});
        }).catchError((Object _) {
          // 单个分区失败不阻塞其它分区；错误由最终判定/分区自身兜底
          if (mounted) setState(() {});
        }));
      }
      await Future.wait(reqs);

      // 只有确实加载到数据时才标记为已加载
      final hasAnyData =
          kugou.recommendSongs.isNotEmpty || kugou.personalFmSongs.isNotEmpty;
      if (!mounted) return;
      if (hasAnyData) {
        kugou.markDiscoverLoaded();
        // 任何一次加载成功都把日期标记为今天
        final prefs = await SharedPreferences.getInstance();
        if (!mounted) return;
        await prefs.setString(_kDiscoverLastDateKey, _todayString());
      }
    } catch (e) {
      if (!mounted) return;
      _error = e.toString();
    }
    if (mounted) {
      setState(() {
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: ScrollAwareAppBar(
        title: '发现',
        tabId: 'discover',
        scrollController: _scrollController,
        // 公开版偏好：无壁纸时顶部恒为不透明 surface（文字区稳定）；
        // 有壁纸时顶栏完全透明，壁纸透出与页面主体透明度上下一致
        opaque: true,
        titleTrailing: _buildGreetingPill(colorScheme),
        actions: [
          _buildActionIcon(
            icon: Icons.search,
            onPressed: () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const SearchPage())),
          ),
          Padding(
            padding: const EdgeInsets.only(right: _kActionTrailingGap),
            child: _buildActionIcon(
              icon: Icons.mic_outlined,
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const SongRecognitionPage()),
              ),
            ),
          ),
        ],
      ),
      body: Md3PullToRefresh(
        onRefresh: _loadAllData,
        // 渐进加载：任一分区数据就绪即退出整页转圈，先显示已获取的分区；
        // 未就绪分区由各自 Selector 在数据到达时自动补出（空数据返回占位）。
        child: _isLoading && !_hasAnySectionData
            ? const Center(child: M3ELoadingIndicator())
            : _error != null && !_hasAnySectionData
            ? _buildError(colorScheme)
            : CustomScrollView(
                controller: _scrollController,
                slivers: [
                  _buildPersonalFmSection(),
                  _buildDailySection(colorScheme),
                  _buildHomeDiscoverSection(colorScheme),
                  const SliverToBoxAdapter(child: SizedBox(height: 80)),
                ],
              ),
      ),
    );
  }

  String _getGreeting() {
    final h = DateTime.now().hour;
    if (h < 6) return '夜深了';
    if (h < 12) return '早上好';
    if (h < 14) return '中午好';
    if (h < 18) return '下午好';
    return '晚上好';
  }

  Widget _buildError(ColorScheme cs) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xxl),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.cloud_off,
              size: 48,
              color: cs.onSurfaceVariant.withValues(alpha: 0.5),
            ),
            const Gap(AppSpacing.md),
            Text(
              '加载失败',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(color: cs.onSurfaceVariant),
            ),
            const Gap(AppSpacing.sm),
            Text(
              _error!,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
              textAlign: TextAlign.center,
            ),
            const Gap(AppSpacing.lg),
            FilledButton.tonal(
              onPressed: _loadAllData,
              child: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }

  /// 三个参数缺一不可：`constraints` 定按钮尺寸，`padding` 让 24dp 的图标塞得进
  /// 36dp 的框，`visualDensity` 改的是 MD3 垫在外面那层 48dp 的布局尺寸——不动它
  /// 按钮画小了、占位照旧。
  Widget _buildActionIcon({
    required IconData icon,
    required VoidCallback onPressed,
  }) {
    return IconButton(
      visualDensity: const VisualDensity(horizontal: -3, vertical: -2),
      constraints: const BoxConstraints.tightFor(
        width: _kActionButtonWidth,
        height: _kActionButtonHeight,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
      icon: Icon(icon),
      onPressed: onPressed,
    );
  }

  /// 问候胶囊，紧跟在顶栏标题右边。宽度贴着文字长短变，上限由标题区剩下的宽度
  /// 决定（见 [ScrollAwareAppBar.titleTrailing]），顶格时由 ellipsis 收尾。
  Widget _buildGreetingPill(ColorScheme cs) {
    final tt = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 6, 10, 6),
      decoration: ShapeDecoration(
        color: cs.primaryContainer,
        shape: const StadiumBorder(),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Selector<KugouProvider, String?>(
              selector: (_, kugou) =>
                  kugou.isLoggedIn ? kugou.userInfo?.nickname : null,
              builder: (context, nickname, _) {
                final greeting = _getGreeting();
                return Text(
                  nickname == null || nickname.isEmpty
                      ? greeting
                      : '$greeting，$nickname',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: tt.labelLarge?.copyWith(
                    color: cs.onPrimaryContainer,
                    fontWeight: FontWeight.w600,
                  ),
                );
              },
            ),
          ),
          const Gap(AppSpacing.xs),
          Icon(Icons.music_note, size: 16, color: cs.onPrimaryContainer),
        ],
      ),
    );
  }

  Widget _buildPersonalFmSection() {
    return const SliverToBoxAdapter(child: PersonalFmSection());
  }

  /// 每日推荐：竖排前四首。
  ///
  /// 原来是 76dp 高的横滑条，是全页最矮的区块——语义最重的内容拿到了最轻的
  /// 视觉权重。而且卡内布局是「封面在左、文字在右」的列表项形态，被硬塞进横滑
  /// 列表：横滑方向和卡内阅读方向一致，眼睛不知道该往哪走。
  ///
  /// 改成竖排后它同时打断了「五连横滑」的单一节奏，并且复用 [SongListItem]，
  /// 顺带拿到「正在播」高亮、收藏、更多菜单（含 MV）——原来的 _DailySongCard 一个都没有。
  /// 全部 30 首仍在标题右侧的 `›` 里。
  Widget _buildDailySection(ColorScheme cs) {
    return Selector<KugouProvider, List<KugouSongDetail>>(
      selector: (_, kugou) => kugou.recommendSongs,
      builder: (context, songs, _) {
        if (songs.isEmpty) return const SliverToBoxAdapter(child: SizedBox());
        final all = songs.map((e) => e.toSong()).toList();
        final top = all.take(4).toList();
        return SliverToBoxAdapter(
          child: _CollapsibleSection(
            title: '每日推荐',
            isExpanded: _isDailyExpanded,
            onToggle: () => _toggleCollapse(
              prefKey: _kCollapsedDaily,
              currentlyExpanded: _isDailyExpanded,
              apply: (v) => _isDailyExpanded = v,
            ),
            trailing: IconButton(
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const _DailyRecommendDetailPage(),
                  ),
                );
              },
              icon: const Icon(Icons.chevron_right),
            ),
            child: Padding(
              // SongListItem 自带 horizontal 10 的内边距，补 6 凑成
              // 与其他区块一致的 16dp 页边距。
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Column(
                children: [
                  for (var i = 0; i < top.length; i++)
                    SongListItem(
                      song: top[i],
                      showDuration: false,
                      // 每日推荐：右侧仅收藏按钮（见改版计划二）。
                      trailingActions: SongTrailingActions.favoriteOnly,
                      onTap: () => context
                          .read<PlayerProvider>()
                          .playOnlinePlaylist(all, i),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// 刷歌推荐：竖排前四首，形态与 [_buildDailySection] 完全一致。
  ///
  /// 刻意复用 [SongListItem] 而不是再造一张卡：这一块和每日推荐在视觉上是同一类
  /// 内容（"挑几首听"），用户不该在同一个页面看到两种行样式；而复用顺带拿到
  /// 「正在播」高亮与收藏按钮，别的都得重写一遍。
  ///
  /// 只渲染前 4 首：这是"刷"的第一屏，越少越像一屏；更多的一批在右侧 `›` 的
  /// 详情页里靠上滑继续（[KugouProvider.fetchMoreHomeDiscover]）。
  Widget _buildHomeDiscoverSection(ColorScheme cs) {
    return Selector<KugouProvider, List<KugouSongDetail>>(
      selector: (_, kugou) => kugou.homeDiscoverSongs,
      builder: (context, details, _) {
        if (details.isEmpty) return const SliverToBoxAdapter(child: SizedBox());
        final all = details.map((e) => e.toSong()).toList();
        final top = all.take(4).toList();
        return SliverToBoxAdapter(
          child: _CollapsibleSection(
            title: '刷歌推荐',
            isExpanded: _isHomeDiscoverExpanded,
            onToggle: () => _toggleCollapse(
              prefKey: _kCollapsedHomeDiscover,
              currentlyExpanded: _isHomeDiscoverExpanded,
              apply: (v) => _isHomeDiscoverExpanded = v,
            ),
            trailing: IconButton(
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const _HomeDiscoverDetailPage(),
                  ),
                );
              },
              icon: const Icon(Icons.chevron_right),
            ),
            child: Padding(
              // SongListItem 自带 horizontal 10 的内边距，补 6 凑成
              // 与其他区块一致的 16dp 页边距。
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Column(
                children: [
                  for (var i = 0; i < top.length; i++)
                    SongListItem(
                      song: top[i],
                      showDuration: false,
                      // 与每日推荐一致：右侧仅收藏按钮，时长对"刷"没有参考价值。
                      trailingActions: SongTrailingActions.favoriteOnly,
                      // 走统一的 _play，卡片上点歌同样要装填补货器
                      onTap: () => _play(i),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// 点一首歌就起播，并把 [HomeDiscoverRefill] 装上，让这条队列在播完之后还能接着刷。
  ///
  /// 顺序和"必须补一批"都是踩出来的：
  /// 1. **先起播再 arm**。补货器是靠识别"当前播放队列是不是刷歌来的"来决定
  ///    留不留场的，而队列是在 [PlayerProvider.playOnlinePlaylist] 里落地的。
  ///    顺序反了的话 arm 那一刻 currentSong 还是上一首，它会把这当成别人的队列
  ///    直接退场，之后这条队列永远不会被补货。
  /// 2. **必须立刻 append 一批**。PlayerProvider 一次只把当前这一首灌进
  ///    audio_service，队列末尾没有任何预加载；不补的话播到队尾就停，"刷歌"
  ///    退化成"听四首就完事"。
  /// 3. **播放源取 provider 的权威列表快照**（homeDiscoverSongsAsSongs），不在本地
  ///    存副本：副本会和补货器追加进 provider 的新歌脱节，队列里就没有后来的歌。
  Future<void> _play(int index) async {
    final kugou = context.read<KugouProvider>();
    final player = context.read<PlayerProvider>();
    final songs = kugou.homeDiscoverSongsAsSongs;
    if (index < 0 || index >= songs.length) return;
    await player.playOnlinePlaylist(songs, index);
    // 装填补货器：同一条队列已在补货会复用现有实例
    final refill = HomeDiscoverRefill.arm(kugou, player);
    if (refill == null) return;
    // 立即补一批
    await refill.append();
  }
}

class _DailyRecommendDetailPage extends StatefulWidget {
  const _DailyRecommendDetailPage();

  @override
  State<_DailyRecommendDetailPage> createState() =>
      _DailyRecommendDetailPageState();
}

class _DailyRecommendDetailPageState extends State<_DailyRecommendDetailPage> {
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await context.read<KugouProvider>().getRecommendDaily();
      if (mounted) setState(() => _isLoading = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('每日推荐')),
      body: SecondaryMiniPlayerHost(
        child: _isLoading
          ? const Center(child: M3ELoadingIndicator())
          : Selector<KugouProvider, List<KugouSongDetail>>(
              selector: (_, kugou) => kugou.recommendSongs,
              builder: (context, recommendSongs, _) {
                final songs = recommendSongs.map((e) => e.toSong()).toList();
                if (songs.isEmpty) return const Center(child: Text('暂无数据'));
                return Column(
                  children: [
                    // 播放全部：把当日的 30 首当一张歌单从头连播。
                    // 形态与专辑/歌单/听书详情页的主行动按钮一致
                    // （FilledButton.icon + play_arrow）。
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                        AppSpacing.lg,
                        AppSpacing.lg,
                        AppSpacing.lg,
                        AppSpacing.sm,
                      ),
                      child: SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: () => context
                              .read<PlayerProvider>()
                              .playOnlinePlaylist(songs, 0),
                          icon: const Icon(Icons.play_arrow),
                          label: const Text('播放全部'),
                        ),
                      ),
                    ),
                    Expanded(
                      child: ListView.builder(
                        padding: EdgeInsets.fromLTRB(
                          AppSpacing.lg,
                          AppSpacing.sm,
                          AppSpacing.lg,
                          AppSpacing.lg + MediaQuery.paddingOf(context).bottom,
                        ),
                        itemCount: songs.length,
                        itemBuilder: (context, index) {
                          final song = songs[index];
                          return SongListItem(
                            song: song,
                            // 每日推荐：右侧仅收藏按钮（见改版计划二）。
                            trailingActions: SongTrailingActions.favoriteOnly,
                            onTap: () {
                              context.read<PlayerProvider>().playOnlinePlaylist(
                                songs,
                                index,
                              );
                            },
                            onMoreTap: () {},
                          );
                        },
                      ),
                    ),
                  ],
                );
              },
            ),
      ),
    );
  }
}

/// 刷歌推荐详情页：完整的一批 + 上滑增量 + 起播补货。
///
/// 骨架照 [_DailyRecommendDetailPage]（Scaffold + AppBar + SecondaryMiniPlayerHost
/// + 「播放全部」+ ListView.builder），差别只有两处：
/// - 列表会随滚动变长：底部哨兵行到距底 200px 就翻一批
///   （[KugouProvider.fetchMoreHomeDiscover]），翻到取不动为止；
/// - 点任意一首都会把 [HomeDiscoverRefill] 装上，播完自动接下一批。
class _HomeDiscoverDetailPage extends StatefulWidget {
  const _HomeDiscoverDetailPage();

  @override
  State<_HomeDiscoverDetailPage> createState() =>
      _HomeDiscoverDetailPageState();
}

class _HomeDiscoverDetailPageState extends State<_HomeDiscoverDetailPage> {
  /// 一批的条数，对齐 [KugouProvider.homeDiscoverBatchSize]。
  /// 传小了的代价是 provider 判定"这一趟没凑够 minCount"就再多试几轮请求，
  /// 白白多发几次网络。
  static const int _pageSize = 30;

  bool _isLoading = true;
  bool _loadingMore = false;
  bool _hasMore = true;

  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      // 与 provider 里的 5 分钟 TTL 对齐：冷启动时首页可能刚取过首屏 4 首，
      // 这里不该再要一次。
      await context.read<KugouProvider>().getHomeDiscover();
      if (!mounted) return;
      setState(() => _isLoading = false);
      await _fillUntilScrollable();
    });
  }

  @override
  void dispose() {
    // 先摘监听再 dispose：controller 在 dispose 之后任何一次 scroll 通知都会
    // 反过来摸已销毁的 controller（scene_audio_list_page 就漏了这一步）。
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  /// 距底 200px 触发翻页：等真正到底再翻会先看到一屏空白（footer 才刚出现）。
  void _onScroll() {
    if (!_scrollController.hasClients) return;
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 200) {
      _loadMore();
    }
  }

  /// 列表装不满一屏时主动补批，直到它真的能滚。
  ///
  /// 这是"只有 4 首时怎么上拉都没反应"的根因：[_onScroll] 挂在 ScrollController
  /// 上，只有**真的发生滚动**才会回调。首屏只有 4 首（`pagesize` 的文档默认值），
  /// 远矮于一屏，`maxScrollExtent` 为 0 —— 根本滚不动，于是回调不触发，
  /// [_loadMore] 永远不被调用。条件本身（`0 >= 0 - 200`）是成立的，只是没人
  /// 去算它。这也是"播放补货正常、滑动失灵"的原因：补货由
  /// [HomeDiscoverRefill] 监听 PlayerProvider 驱动，与滚动毫无关系。
  ///
  /// 所以不能把"取下一批"只挂在滚动上——首屏那一段没有任何滚动事件可听。
  static const int _maxAutoFillRounds = 4;

  /// 防止 [_loadMoreBatch] 末尾再调本方法时递归：[_fillUntilScrollable] 内部
  /// 会调 [_loadMore]，后者又回调进来，没有这道闸就会变成无限自我调用。
  bool _autoFilling = false;

  Future<void> _fillUntilScrollable() async {
    if (_autoFilling) return;
    _autoFilling = true;
    try {
      for (var round = 0; round < _maxAutoFillRounds; round++) {
        if (!mounted || !_hasMore) return;
        // 等新条目布局完再量，否则量到的还是补货前的 maxScrollExtent。
        await WidgetsBinding.instance.endOfFrame;
        if (!mounted) return;
        // maxScrollExtent > 0 表示已经能滚了，交给用户上拉即可。
        if (_scrollController.hasClients &&
            _scrollController.position.maxScrollExtent > 0) {
          return;
        }
        await _loadMore();
      }
    } finally {
      _autoFilling = false;
    }
  }

  /// 上拉翻一批。复位放在 finally：翻页失败（网络/上游返回 null）时若不复位，
  /// 指示器会一直转、之后再怎么滚都不会加载，等于把整页的增量永久卡死。
  /// 翻转 [_loadingMore] 必须走 setState：footer 的转圈分支渲染依赖列表重建，
  /// 只改字段不重建的话指示器从出现到消失都不会画出来。
  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore) return;
    setState(() => _loadingMore = true);
    try {
      await _loadMoreBatch();
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  Future<void> _loadMoreBatch() async {
    final kugou = context.read<KugouProvider>();
    final fresh = await kugou.fetchMoreHomeDiscover(minCount: _pageSize);
    if (!mounted) return;
    // 列表本身由 provider 追加（fetchMoreHomeDiscover 内部已经并进
    // homeDiscoverSongs 并 notifyListeners），这里只判"还有没有"。
    setState(() {
      _hasMore = fresh.isNotEmpty;
    });
    // 补完一批后再确认一次能否滚动：大屏/折叠屏展开态下，一屏装得下 30 首，
    // 光靠首屏那次自动补货还是滚不动。
    await _fillUntilScrollable();
  }

  /// 点歌起播 + 装填补货器。
  ///
  /// 三点顺序的原因与 [_DiscoverPageState._play] 完全一致（那是同一套起播逻辑的
  /// 卡片版本，这里只重复结论）：
  /// 1. **先 [PlayerProvider.playOnlinePlaylist] 再 arm**：队列要先落地，补货器才
  ///    认得出这条队列是刷歌来的；反了的话 arm 那一刻 currentSong 还是上一首，会被
  ///    当成「别人的队列」直接退场。
  /// 2. **必须立即 append 一批**：PlayerProvider 一次只把一首歌灌进 audio_service，
  ///    队尾没有预加载；不补就是播到头就停。
  /// 3. **不在本 State 存 List&lt;Song&gt; 副本**：本页展示的是
  ///    [KugouProvider.homeDiscoverSongs]（Selector 监听），补货器往里追加后本页
  ///    会自然变长。存一份副本的话，副本既不会变长，也会和补货器判断队列归属时
  ///    依据的 provider 列表对不上。
  Future<void> _play(int index) async {
    final kugou = context.read<KugouProvider>();
    final player = context.read<PlayerProvider>();
    final songs = kugou.homeDiscoverSongsAsSongs;
    if (index < 0 || index >= songs.length) return;
    await player.playOnlinePlaylist(songs, index);
    // 装填补货器：同一条队列已在补货会复用现有实例
    final refill = HomeDiscoverRefill.arm(kugou, player);
    if (refill == null) return;
    // 立即补一批
    await refill.append();
  }

  /// 列表尾部哨兵行：加载中转圈 / 还有更多时提示上滑 / 取完了说一声。
  /// 三态都留着是因为"还在转"和"到底了"不写清楚的话，用户会以为页面卡住。
  Widget _buildListFooter(BuildContext context) {
    if (_loadingMore) {
      // 与下拉刷新同款：M3EPullToRefreshIndicator 默认用的 M3EContainedLoadingIndicator，
      // 48×48 药丸容器 + shapes 动画，视觉与发现页/刷刷页的下拉刷新一致。
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Center(
          child: M3EContainedLoadingIndicator(
            width: 48,
            height: 48,
          ),
        ),
      );
    }
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Center(
        child: Text(
          _hasMore ? '继续上滑加载更多' : '没有更多了',
          style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('刷歌推荐')),
      body: SecondaryMiniPlayerHost(
        child: _isLoading
            ? const Center(child: M3ELoadingIndicator())
            : Selector<KugouProvider, List<KugouSongDetail>>(
                selector: (_, kugou) => kugou.homeDiscoverSongs,
                builder: (context, details, _) {
                  final songs = details.map((e) => e.toSong()).toList();
                  if (songs.isEmpty) return const Center(child: Text('暂无数据'));
                  return Column(
                    children: [
                      // 播放全部：与每日推荐详情页同形态（FilledButton.icon +
                      // play_arrow），点它也走 _play(0)，同样会装上补货器。
                      Padding(
                        padding: const EdgeInsets.fromLTRB(
                          AppSpacing.lg,
                          AppSpacing.lg,
                          AppSpacing.lg,
                          AppSpacing.sm,
                        ),
                        child: SizedBox(
                          width: double.infinity,
                          child: FilledButton.icon(
                            onPressed: () => _play(0),
                            icon: const Icon(Icons.play_arrow),
                            label: const Text('播放全部'),
                          ),
                        ),
                      ),
                      Expanded(
                        child: ListView.builder(
                          controller: _scrollController,
                          padding: EdgeInsets.fromLTRB(
                            AppSpacing.lg,
                            AppSpacing.sm,
                            AppSpacing.lg,
                            AppSpacing.lg + MediaQuery.paddingOf(context).bottom,
                          ),
                          // +1 是底部哨兵行，兼作翻页指示与"没有更多"的落点。
                          itemCount: songs.length + 1,
                          itemBuilder: (context, index) {
                            if (index == songs.length) {
                              return _buildListFooter(context);
                            }
                            return SongListItem(
                              song: songs[index],
                              // 与卡片一致：右侧仅收藏按钮。
                              trailingActions: SongTrailingActions.favoriteOnly,
                              onTap: () => _play(index),
                              onMoreTap: () {},
                            );
                          },
                        ),
                      ),
                    ],
                  );
                },
              ),
      ),
    );
  }
}

/// 可折叠 section 容器：
/// - 标题行左侧可点击区域（标题 + chevron 图标）触发 onToggle 折叠/展开
/// - 标题行右侧可放额外 widget（如"查看更多"按钮）
/// - 内容用 AnimatedCrossFade 在展示态和零高度态间平滑过渡
class _CollapsibleSection extends StatelessWidget {
  const _CollapsibleSection({
    required this.title,
    required this.isExpanded,
    required this.onToggle,
    required this.child,
    this.trailing,
  });

  final String title;
  final bool isExpanded;
  final VoidCallback onToggle;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            AppSpacing.md,
            AppSpacing.lg,
            AppSpacing.sm,
          ),
          child: Row(
            children: [
              Expanded(
                child: InkWell(
                  onTap: onToggle,
                  borderRadius: AppRadius.smAll,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          child: Text(
                            title,
                            style: tt.titleMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const Gap(AppSpacing.xs),
                        AnimatedRotation(
                          turns: isExpanded ? 0.5 : 0,
                          duration: const Duration(milliseconds: 200),
                          child: Icon(
                            Icons.expand_more,
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              ?trailing,
            ],
          ),
        ),
        AnimatedCrossFade(
          duration: const Duration(milliseconds: 200),
          crossFadeState: isExpanded
              ? CrossFadeState.showFirst
              : CrossFadeState.showSecond,
          sizeCurve: Curves.easeInOut,
          firstChild: child,
          secondChild: const SizedBox(width: double.infinity),
        ),
      ],
    );
  }
}
