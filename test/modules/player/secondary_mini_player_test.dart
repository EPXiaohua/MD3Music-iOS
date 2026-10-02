import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:md3music/core/layout/responsive_layout.dart';
import 'package:md3music/core/services/player_frame_driver.dart';
import 'package:md3music/data/repositories/settings_repository.dart';
import 'package:md3music/data/models/song.dart';
import 'package:md3music/modules/player/full_player_route.dart';
import 'package:md3music/modules/player/mini_player.dart';
import 'package:md3music/modules/player/secondary_mini_player.dart';
import 'package:md3music/providers/car_mode_provider.dart';
import 'package:md3music/providers/device_provider.dart';
import 'package:md3music/providers/player_provider.dart';
import 'package:md3music/providers/theme_provider.dart';

/// 只覆写播放态相关 getter 的假 provider。
///
/// 测试环境没有音频平台实现，真实 `playPlaylist` 起不了播（`isPlaying` 恒 false），
/// 故沿用本仓既有做法（见 `test/modules/personal_fm/personal_fm_section_test.dart`
/// 的 `_FakePlayer`）直接注入播放态。
class _FakePlayer extends PlayerProvider {
  Song? _song;
  bool _playing = false;

  @override
  Song? get currentSong => _song;

  @override
  bool get isPlaying => _playing;

  void simulate({Song? song, bool? playing}) {
    if (song != null) _song = song;
    if (playing != null) _playing = playing;
    notifyListeners();
  }
}

/// ⚠️ Flutter 测试默认视口是 800×600，其 `shortestSide` **恰好 = 600** →
/// `isPadLayout` 会判为 true。所以凡涉及布局分支的用例都必须显式指定视口。
void _setViewport(WidgetTester tester, Size logical) {
  tester.view.devicePixelRatio = 3.0;
  tester.view.physicalSize = Size(logical.width * 3, logical.height * 3);
  addTearDown(tester.view.reset);
}

/// 手机（最短边 400 < 600）：竖屏。
const Size _kPhonePortrait = Size(400, 869);

/// Pad（最短边 800 ≥ 600）：竖屏。
const Size _kPadPortrait = Size(800, 1280);

/// [SecondaryMiniPlayer] 的既有约定：
/// - 帧率：唱片旋转必须走共享 60fps 节拍（不得用 Ticker），不可见时必须解绑（AGENTS.md §10）；
/// - 停靠：手机水平居中（原行为），Pad 右下停靠且限宽。
void main() {
  Song song(String id) => Song(
    id: id,
    title: '标题',
    artist: 'artist',
    album: 'album',
    duration: const Duration(seconds: 60),
  );

  late _FakePlayer player;
  late CarModeProvider carMode;
  late ValueNotifier<bool> collapsed;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    // 全局开关/进度是跨用例共享的 ValueNotifier，必须显式复位。
    playerExpansion.value = 0.0;
    kSecondaryPlayerEnabled.value = true;
    kSecondaryPlayerDock.value = SecondaryPlayerDockSide.center;
    collapsed = ValueNotifier<bool>(true);
    player = _FakePlayer()..simulate(song: song('s0'), playing: true);
    carMode = CarModeProvider();
  });

  tearDown(() {
    collapsed.dispose();
    player.dispose();
    carMode.dispose();
    playerExpansion.value = 0.0;
    kSecondaryPlayerEnabled.value = true;
    kSecondaryPlayerDock.value = SecondaryPlayerDockSide.center;
  });

  Widget host({bool tickerEnabled = true}) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<PlayerProvider>.value(value: player),
        ChangeNotifierProvider<CarModeProvider>.value(value: carMode),
        ChangeNotifierProvider<DeviceProvider>(create: (_) => DeviceProvider()),
        ChangeNotifierProvider<ThemeProvider>(create: (_) => ThemeProvider()),
      ],
      child: MaterialApp(
        home: Scaffold(
          // 与生产一致：宿主 SecondaryMiniPlayerHost 把播放器放在
          // Stack 的 Positioned(left:0,right:0,bottom:0) 里。
          body: Stack(
            children: <Widget>[
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: TickerMode(
                  enabled: tickerEnabled,
                  child: SecondaryMiniPlayer(
                    collapsed: collapsed,
                    onRequestExpand: () {},
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 挂在**二级路由**上的宿主：悬浮播放器只在二级页面渲染
  /// （`isSecondaryRoutePage` 判据），故必须用 push 出来的路由承载。
  ///
  /// [child] 用于探测宿主注入的底部预留 padding（默认空盒子）。
  Widget hostOnSecondaryRoute({Widget? child}) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<PlayerProvider>.value(value: player),
        ChangeNotifierProvider<CarModeProvider>.value(value: carMode),
        ChangeNotifierProvider<DeviceProvider>(create: (_) => DeviceProvider()),
        ChangeNotifierProvider<ThemeProvider>(create: (_) => ThemeProvider()),
      ],
      child: MaterialApp(
        initialRoute: '/detail',
        routes: <String, WidgetBuilder>{
          '/': (_) => const SizedBox(),
          '/detail': (_) => Scaffold(
            body: Stack(
              children: <Widget>[
                Positioned.fill(
                  child: SecondaryMiniPlayerHost(child: child ?? const SizedBox()),
                ),
              ],
            ),
          ),
        },
      ),
    );
  }

  /// 挂在**一级路由**（栈底 `home:`）上的宿主：主页（tab 页）现在同样由
  /// 悬浮播放器承载（不再按 `isSecondaryRoutePage` 区分一/二级）。
  Widget hostOnPrimaryRoute({Widget? child}) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<PlayerProvider>.value(value: player),
        ChangeNotifierProvider<CarModeProvider>.value(value: carMode),
        ChangeNotifierProvider<DeviceProvider>(create: (_) => DeviceProvider()),
        ChangeNotifierProvider<ThemeProvider>(create: (_) => ThemeProvider()),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Stack(
            children: <Widget>[
              Positioned.fill(
                child: SecondaryMiniPlayerHost(child: child ?? const SizedBox()),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 胶囊本体：按 32dp 胶囊圆角定位，不依赖视觉 elevation。
  Finder capsule(WidgetTester tester) {
    final f = find.descendant(
      of: find.byType(SecondaryMiniPlayer),
      matching: find.byWidgetPredicate(
        (w) => w is Material && w.borderRadius == BorderRadius.circular(32),
      ),
    );
    expect(f, findsOneWidget, reason: '胶囊应唯一可定位');
    return f;
  }

  testWidgets('浮动迷你播放器的歌曲名和歌手居中对齐', (tester) async {
    _setViewport(tester, _kPhonePortrait);
    collapsed.value = false;
    await tester.pumpWidget(host());
    await tester.pump();

    expect(tester.widget<Text>(find.text('标题')).textAlign, TextAlign.center);
    expect(tester.widget<Text>(find.text('artist')).textAlign, TextAlign.center);

    await tester.pumpWidget(const SizedBox());
  });

  // —— 帧率约定（AGENTS.md §10）——

  testWidgets('播放中且可见：挂共享 60fps 驱动，且不启动 Ticker', (tester) async {
    _setViewport(tester, _kPhonePortrait);
    await tester.pumpWidget(host());
    await tester.pump();

    expect(
      PlayerFrameDriver.instance.hasListeners,
      isTrue,
      reason: '唱片旋转应挂共享 60fps 节拍（§10.3）',
    );
    expect(
      tester.binding.transientCallbackCount,
      0,
      reason: '唱片旋转不得由 Ticker 驱动（AGENTS.md §10.4.1）',
    );

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('暂停：解绑驱动（保留当前角度）', (tester) async {
    _setViewport(tester, _kPhonePortrait);
    await tester.pumpWidget(host());
    await tester.pump();
    expect(PlayerFrameDriver.instance.hasListeners, isTrue);

    player.simulate(playing: false);
    await tester.pump();

    expect(PlayerFrameDriver.instance.hasListeners, isFalse);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('全屏播放器已展开（卡片 opacity=0）：解绑驱动', (tester) async {
    _setViewport(tester, _kPhonePortrait);
    await tester.pumpWidget(host());
    await tester.pump();
    expect(PlayerFrameDriver.instance.hasListeners, isTrue);

    playerExpansion.value = 1.0;
    await tester.pump();

    expect(
      PlayerFrameDriver.instance.hasListeners,
      isFalse,
      reason: 'DraggablePlayerRoute 是 opaque=false，TickerMode 不会自动关，'
          '必须按 playerExpansion 停帧（§10.4.3）',
    );

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('TickerMode 关闭（被覆盖 / 切走）：解绑驱动', (tester) async {
    _setViewport(tester, _kPhonePortrait);
    await tester.pumpWidget(host());
    await tester.pump();
    expect(PlayerFrameDriver.instance.hasListeners, isTrue);

    await tester.pumpWidget(host(tickerEnabled: false));
    await tester.pump();

    expect(PlayerFrameDriver.instance.hasListeners, isFalse);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('dispose 后解绑，不留 pending timer', (tester) async {
    _setViewport(tester, _kPhonePortrait);
    await tester.pumpWidget(host());
    await tester.pump();
    expect(PlayerFrameDriver.instance.hasListeners, isTrue);

    await tester.pumpWidget(const SizedBox());

    expect(PlayerFrameDriver.instance.hasListeners, isFalse);
  });

  // —— 停靠位置（手机居中 / Pad 右下限宽）——

  testWidgets('手机竖屏：维持原样（展开态撑满可用宽、水平居中）', (tester) async {
    _setViewport(tester, _kPhonePortrait);
    collapsed.value = false; // 展开态
    await tester.pumpWidget(host());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400)); // 形变收敛到展开态

    final rect = tester.getRect(capsule(tester));
    // 可用宽 = 视口宽 - 左右各 16 内边距
    expect(rect.width, closeTo(_kPhonePortrait.width - 32, 0.5));
    expect(
      rect.center.dx,
      closeTo(_kPhonePortrait.width / 2, 0.5),
      reason: '手机必须保持水平居中（上游约束：手机竖屏/横屏完全不变）',
    );

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Pad：展开态胶囊限宽 400 且贴右下角', (tester) async {
    _setViewport(tester, _kPadPortrait);
    collapsed.value = false; // 展开态
    kSecondaryPlayerDock.value = SecondaryPlayerDockSide.right; // 单测无启动装载，显式设默认
    await tester.pumpWidget(host());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    final rect = tester.getRect(capsule(tester));
    expect(
      rect.width,
      closeTo(kSecondaryPlayerPadMaxWidth, 0.5),
      reason: 'Pad 下轨道限宽，胶囊不再横贯全屏',
    );
    expect(
      rect.right,
      closeTo(_kPadPortrait.width - 16, 0.5),
      reason: '右缘贴容器右内边距（16dp）',
    );

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Pad 收起态：圆盘贴右缘（不再居中）', (tester) async {
    _setViewport(tester, _kPadPortrait);
    collapsed.value = true; // 初始即收起
    kSecondaryPlayerDock.value = SecondaryPlayerDockSide.right; // 单测无启动装载，显式设默认
    await tester.pumpWidget(host());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    final rect = tester.getRect(capsule(tester));
    expect(rect.width, closeTo(64.0, 0.5), reason: '收起态直径 = _disc(64)');
    expect(
      rect.right,
      closeTo(_kPadPortrait.width - 16, 0.5),
      reason: '收起态圆盘应贴右下角，而不是屏幕中央',
    );

    await tester.pumpWidget(const SizedBox());
  });

  // —— 悬浮播放器总开关（设置页可关）——

  testWidgets('默认开启：宿主渲染悬浮条并注入底部预留（+76）', (tester) async {
    _setViewport(tester, _kPhonePortrait);
    double probedBottom = -1;
    await tester.pumpWidget(
      hostOnSecondaryRoute(
        child: Builder(
          builder: (context) {
            probedBottom = MediaQuery.paddingOf(context).bottom;
            return const SizedBox.expand();
          },
        ),
      ),
    );
    await tester.pump();

    expect(kSecondaryPlayerEnabled.value, isTrue);
    expect(find.byType(SecondaryMiniPlayer), findsOneWidget);
    expect(
      probedBottom,
      closeTo(76.0, 0.5),
      reason: '宿主应注入 _kReservedBottom，否则列表末项会被悬浮栏遮挡',
    );

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('关闭开关（二级页面）：回退为底部常驻播放条', (tester) async {
    _setViewport(tester, _kPhonePortrait);
    kSecondaryPlayerEnabled.value = false;
    double probedBottom = -1;
    await tester.pumpWidget(
      hostOnSecondaryRoute(
        child: Builder(
          builder: (context) {
            probedBottom = MediaQuery.paddingOf(context).bottom;
            return const SizedBox.expand();
          },
        ),
      ),
    );
    await tester.pump();

    expect(
      find.byType(SecondaryMiniPlayer),
      findsNothing,
      reason: '关闭后二级页面不再渲染悬浮播放器',
    );
    expect(
      find.byType(MiniPlayer),
      findsOneWidget,
      reason: '关闭后二级页面应回退为底部常驻播放条（与主页同一条）',
    );
    expect(
      probedBottom,
      closeTo(0.0, 0.5),
      reason: '回落形态用 Column（真实布局空间）承载，无需注入底部预留',
    );

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('运行时切换开关：即时生效（无需重建整页）', (tester) async {
    _setViewport(tester, _kPhonePortrait);
    await tester.pumpWidget(hostOnSecondaryRoute());
    await tester.pump();
    expect(find.byType(SecondaryMiniPlayer), findsOneWidget);

    kSecondaryPlayerEnabled.value = false;
    await tester.pump();
    expect(find.byType(SecondaryMiniPlayer), findsNothing);

    kSecondaryPlayerEnabled.value = true;
    await tester.pump();
    expect(find.byType(SecondaryMiniPlayer), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  // —— 一级页面（主页）同样由悬浮播放器承载，受同一开关控制 ——

  testWidgets('一级页面 + 开关开启：渲染悬浮播放器（不再退化为透传）', (tester) async {
    _setViewport(tester, _kPhonePortrait);
    double probedBottom = -1;
    await tester.pumpWidget(
      hostOnPrimaryRoute(
        child: Builder(
          builder: (context) {
            probedBottom = MediaQuery.paddingOf(context).bottom;
            return const SizedBox.expand();
          },
        ),
      ),
    );
    await tester.pump();

    expect(
      find.byType(SecondaryMiniPlayer),
      findsOneWidget,
      reason: '主页（栈底路由）也应渲染悬浮播放器，统一受开关控制',
    );
    expect(
      probedBottom,
      closeTo(76.0, 0.5),
      reason: '主页底部同样需要预留悬浮条高度',
    );

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('一级页面 + 开关关闭：不渲染悬浮播放器（底部条由 shell 承载）', (tester) async {
    _setViewport(tester, _kPhonePortrait);
    kSecondaryPlayerEnabled.value = false;
    await tester.pumpWidget(hostOnPrimaryRoute());
    await tester.pump();

    expect(find.byType(SecondaryMiniPlayer), findsNothing);
    // 主页的底部常驻条由 _MainLayout 的 shell 渲染（不在本测试宿主内），
    // 宿主不得再补一条，否则主页会出现两条播放器。
    expect(find.byType(MiniPlayer), findsNothing);

    await tester.pumpWidget(const SizedBox());
  });

  // —— 折叠态拖拽 + 三点吸附 ——

  /// 把圆盘水平拖动 [dx] 并松手（一次拖拽含触发吸附）。
  Future<void> dragDisc(WidgetTester tester, double dx) async {
    await tester.drag(capsule(tester), Offset(dx, 0));
    // 吸附动画 220ms，用固定时长 pump 而非 pumpAndSettle：
    // 播放中时共享帧驱动（PlayerFrameDriver 的 Timer）会让 pumpAndSettle 难以收敛。
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('手机默认停靠位为中下（折叠态圆盘居中）', (tester) async {
    _setViewport(tester, _kPhonePortrait);
    collapsed.value = true;
    kSecondaryPlayerDock.value = SecondaryPlayerDockSide.center;
    await tester.pumpWidget(host());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    final rect = tester.getRect(capsule(tester));
    expect(rect.width, closeTo(64.0, 0.5));
    expect(
      rect.center.dx,
      closeTo(_kPhonePortrait.width / 2, 0.5),
      reason: '手机默认停靠位 = 中下',
    );

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('向右拖动后吸附到右下，并持久化', (tester) async {
    _setViewport(tester, _kPhonePortrait);
    collapsed.value = true;
    kSecondaryPlayerDock.value = SecondaryPlayerDockSide.center;
    await tester.pumpWidget(host());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    await dragDisc(tester, 200);

    final rect = tester.getRect(capsule(tester));
    expect(
      rect.right,
      closeTo(_kPhonePortrait.width - 16, 0.5),
      reason: '吸附到右下：右缘 = 视口宽 - 16',
    );
    expect(
      kSecondaryPlayerDock.value,
      SecondaryPlayerDockSide.right,
      reason: '吸附后应更新全局停靠位',
    );
    expect(
      await SettingsRepository().getSecondaryPlayerDockRaw(),
      'right',
      reason: '吸附结果应持久化（重启保持）',
    );

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('向左拖动后吸附到左下', (tester) async {
    _setViewport(tester, _kPhonePortrait);
    collapsed.value = true;
    kSecondaryPlayerDock.value = SecondaryPlayerDockSide.center;
    await tester.pumpWidget(host());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    await dragDisc(tester, -200);

    final rect = tester.getRect(capsule(tester));
    expect(rect.left, closeTo(16.0, 0.5), reason: '吸附到左下：左缘 = 16');

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('拖拽超出轨道边界：被钳制，不会跑出屏幕', (tester) async {
    _setViewport(tester, _kPhonePortrait);
    collapsed.value = true;
    kSecondaryPlayerDock.value = SecondaryPlayerDockSide.center;
    await tester.pumpWidget(host());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    await dragDisc(tester, -5000);

    final rect = tester.getRect(capsule(tester));
    expect(rect.left, closeTo(16.0, 0.5), reason: '钳制到左缘 16');

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('展开态拖拽无效（胶囊不随拖拽移动）', (tester) async {
    _setViewport(tester, _kPhonePortrait);
    collapsed.value = false; // 展开态
    kSecondaryPlayerDock.value = SecondaryPlayerDockSide.center;
    await tester.pumpWidget(host());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    final before = tester.getRect(capsule(tester));
    await tester.drag(capsule(tester), Offset(200, 0));
    await tester.pump(const Duration(milliseconds: 300));
    final after = tester.getRect(capsule(tester));

    expect(after, before, reason: '拖拽语义只针对折叠态圆盘');

    await tester.pumpWidget(const SizedBox());
  });
}
