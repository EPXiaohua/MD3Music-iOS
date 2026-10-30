// 私人 FM 横屏：FM 卡片和即将播放在左列，推荐选项卡片在右列。
// 验证真实几何位置，动作按钮继续留在 FM 卡片中，竖屏保持单栏。
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/theme/app_theme.dart';
import 'package:md3music/data/models/song.dart';
import 'package:md3music/modules/personal_fm/personal_fm_page.dart';
import 'package:md3music/modules/personal_fm/personal_fm_page_preferences.dart';
import 'package:md3music/providers/favorites_provider.dart';
import 'package:md3music/providers/kugou_provider.dart';
import 'package:md3music/providers/player_provider.dart';
import 'package:md3music/providers/tab_config_provider.dart';
import 'package:md3music/providers/theme_provider.dart';
import 'package:md3music/services/kugou_api/kugou_models.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeKugou extends ChangeNotifier implements KugouProvider {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
  _FakeKugou(this.songs);

  final List<KugouSongDetail> songs;

  @override
  bool get isLoggedIn => true;

  @override
  List<KugouSongDetail> get personalFmSongs => songs;

  @override
  List<Song> get personalFmAsSongs => songs.map((e) => e.toSong()).toList();

  @override
  Future<List<KugouSongDetail>?> reportPersonalFmAction({
    required String action,
    String? mode,
    int? songPoolId,
    String? hash,
    String? songId,
    String? curMark,
    int? playtime,
    bool isOverplay = false,
  }) async => null;

  @override
  Future<void> getPersonalFm({
    String? mode,
    int? songPoolId,
    String? hash,
    String? songId,
    String? action,
    bool noCache = false,
    bool forceRefresh = false,
  }) async {}
}

class _FakePlayer extends PlayerProvider {
  Song? _song;

  @override
  Song? get currentSong => _song;

  @override
  bool get isPlaying => false;

  @override
  List<Song> get playlist => const [];

  @override
  int get currentIndex => -1;

  // 真实 getter 从 audio_service 回填（测试里没起引擎）。本页的播放器通知回调
  // 每次都会采这两个值，直接喂常量免得将来加了 notifyListeners 就挂。
  @override
  Duration get position => Duration.zero;

  @override
  Duration? get duration => null;

  void simulate(Song song) => _song = song;

  @override
  Future<void> next({bool autoPlay = true}) async {}

  @override
  Future<void> appendPlaylist(List<Song> songs) async {}
}

/// 收藏按钮走 Selector 读 [FavoritesProvider]；真实实现会去查库+发网（测试里两者
/// 都不存在），用内存账本顶掉。
class _FakeFavorites extends FavoritesProvider {
  @override
  Future<void> loadFavorites() async {}

  @override
  bool isFavorite(String songId) => false;
}

const List<KugouSongDetail> _songs = [
  KugouSongDetail(hash: 'h0', songName: 'song 0', artistName: 'a0'),
  KugouSongDetail(hash: 'h1', songName: 'song 1', artistName: 'a1'),
  KugouSongDetail(hash: 'h2', songName: 'song 2', artistName: 'a2'),
];

void main() {
  Future<void> drainProviderStartup(WidgetTester tester) =>
      tester.pump(const Duration(seconds: 5));

  Future<void> pumpPage(
    WidgetTester tester, {
    required Size size,
    _FakePlayer? player,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final kugou = _FakeKugou(List.of(_songs));
    final fakePlayer = player ?? _FakePlayer();
    // 让播放器停在第一首上：卡片渲染的就是它，播放按钮画暂停。
    fakePlayer.simulate(_songs[0].toSong());

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<KugouProvider>.value(value: kugou),
          ChangeNotifierProvider<PlayerProvider>.value(value: fakePlayer),
          ChangeNotifierProvider<FavoritesProvider>(
            // loadFavorites 已被 override 成空实现（见 _FakeFavorites），
            // 构造时那次自动同步不会真去查库/发网。
            create: (_) => _FakeFavorites(),
          ),
          // ScrollAwareAppBar watch ThemeProvider（背景图开关），
          // centerPageTitle watch TabConfigProvider（标题对齐）。
          ChangeNotifierProvider<ThemeProvider>(create: (_) => ThemeProvider()),
          ChangeNotifierProvider<TabConfigProvider>(
            create: (_) => TabConfigProvider(),
          ),
        ],
        child: MaterialApp(
          theme: ThemeData(
            useMaterial3: true,
            colorScheme: ColorScheme.fromSeed(
              seedColor: AppTheme.defaultSeedColor,
            ),
          ),
          home: const PersonalFmPage(),
        ),
      ),
    );
    await tester.pump();
  }

  /// 卡片封面：图片没 URL 时 _cover 仍给出一个 radius 24 的 [ClipRRect]（预告封面
  /// 是 12、其它封面是 16，24 只有 hero 用）。刻意不去量里面的占位图标：
  /// `_coverPlaceholder` 的图标边长是封面尺寸的 0.36 倍，量它等于在量一个魔法比例。
  Finder heroCover() => find.byWidgetPredicate(
    (w) => w is ClipRRect && w.borderRadius == BorderRadius.circular(24),
  );

  Finder stationSwitcher() => find.byKey(const ValueKey('fm-mode-normal'));

  testWidgets('横屏两栏：队列在 FM 卡片左下，推荐选项在右列，动作按钮留在卡片内', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await pumpPage(tester, size: const Size(900, 420));

    final cover = tester.getRect(heroCover());
    final play = tester.getCenter(find.byIcon(Icons.play_arrow));
    final heart = tester.getCenter(find.byIcon(Icons.favorite_border));
    final station = tester.getCenter(stationSwitcher());
    final queue = tester.getCenter(find.text('即将播放'));

    final hero = tester.getRect(find.byKey(const ValueKey('fm-hero-card')));
    final controls = tester.getRect(
      find.byKey(const ValueKey('fm-recommendation-controls')),
    );
    final upcoming = tester.getRect(
      find.byKey(const ValueKey('fm-upcoming-queue')),
    );
    expect(controls.left, greaterThan(hero.right));
    expect(controls.top, closeTo(hero.top, .1));
    expect(upcoming.left, closeTo(hero.left, .1));
    expect(upcoming.right, closeTo(hero.right, .1));
    expect(upcoming.top, closeTo(hero.bottom + 16, .1));
    expect(queue.dy, greaterThan(play.dy));
    expect(play.dy, greaterThan(cover.bottom));
    expect(heart.dy, greaterThan(cover.bottom));
    expect(play.dx, lessThan(station.dx));

    await drainProviderStartup(tester);
  });

  testWidgets('竖屏仍是单栏：按钮在封面下方，队列在更下方', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await pumpPage(tester, size: const Size(400, 900));

    final coverBottom = tester.getRect(heroCover()).bottom;
    final playCenter = tester.getCenter(find.byIcon(Icons.play_arrow));
    final queueCenter = tester.getCenter(find.text('即将播放'));

    expect(
      playCenter.dy,
      greaterThan(coverBottom),
      reason: '竖屏按钮必须在封面下方（上下堆叠），不能变成右侧两栏',
    );
    expect(queueCenter.dy, greaterThan(playCenter.dy), reason: '竖屏队列在按钮行之下');

    await drainProviderStartup(tester);
  });

  testWidgets('横屏封面按视口高度收缩，右列选项与左侧队列标题落进首屏', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await pumpPage(tester, size: const Size(900, 420));

    final cover = tester.getRect(heroCover());
    // 竖屏走的是「按宽度封顶 320」；横屏左列只有 ~457dp 宽，若不引入高度约束，
    // 封面会取到宽度预算，把动作行整块顶出首屏。
    expect(cover.height, lessThan(300), reason: '横屏封面要受视口高度约束，不能沿用竖屏的 320 上限');
    expect(cover.height, greaterThan(100), reason: '不能缩到不可辨');

    // 用户要的是「按钮留在卡片里」，那它就必须真的还在首屏内摸得到——这是
    // 卡片内部改横排 + 封面让出高度共同保证的结果。
    expect(
      tester.getCenter(find.byIcon(Icons.play_arrow)).dy,
      lessThan(420),
      reason: '动作按钮留在卡内，且必须落在首屏内',
    );

    // 右列选项和左列队列标题在首屏内，队列剩余内容可通过整页滚动访问。
    expect(
      tester.getCenter(stationSwitcher()).dy,
      lessThan(420),
      reason: '档位切换必须在首屏内',
    );
    expect(
      tester.getCenter(find.text('即将播放')).dy,
      lessThan(420),
      reason: '「即将播放」标题必须在首屏内',
    );

    await drainProviderStartup(tester);
  });

  // 常见的横屏手机尺寸。封面预算取 0.40 * 高，左列内宽约 (总宽-间距)/2 - 48，
  // 两列都装得下，且不该有任何 RenderFlex 溢出（溢出会以 FlutterError 抛出）。
  for (final size in const [Size(800, 400), Size(720, 360)]) {
    testWidgets('窄横屏 $size 两栏不溢出且右列仍在右侧', (tester) async {
      SharedPreferences.setMockInitialValues({});
      await pumpPage(tester, size: size);

      final cover = tester.getRect(heroCover());
      final station = tester.getCenter(stationSwitcher());
      expect(
        station.dx,
        greaterThan(cover.right),
        reason: '窄横屏下档位/歌池也必须留在右列（这才是腾出高度的手段）',
      );
      expect(find.text('即将播放'), findsOneWidget);

      await drainProviderStartup(tester);
    });
  }
  for (final size in const [Size(400, 900), Size(900, 420)]) {
    testWidgets('选择卡片可点击并持久化 $size', (tester) async {
      SharedPreferences.setMockInitialValues({});
      await pumpPage(tester, size: size);
      final mode = find.byKey(const ValueKey('fm-mode-small'));
      await tester.ensureVisible(mode);
      await tester.pumpAndSettle();
      await tester.tap(mode);
      await tester.pumpAndSettle();
      final pool = find.byKey(const ValueKey('fm-pool-1'));
      await tester.ensureVisible(pool);
      await tester.pumpAndSettle();
      await tester.tap(pool);
      await tester.pumpAndSettle();
      final selection = await PersonalFmPagePreferences.load();
      expect(selection.mode, 'small');
      expect(selection.songPoolId, 1);
      final selectedSemantics = find.ancestor(
        of: pool,
        matching: find.byType(Semantics),
      );
      expect(
        tester.widget<Semantics>(selectedSemantics.first).properties.selected,
        isTrue,
      );
      expect(tester.takeException(), isNull);
      await drainProviderStartup(tester);
    });
  }
}
