import 'dart:async';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/physics.dart';

import '../../core/theme/motion_constants.dart';
import '../../core/layout/page_title_alignment.dart';
import '../../core/layout/responsive_layout.dart';
import '../../core/services/player_frame_driver.dart';
import '../../core/utils/app_haptics.dart';
import '../../data/repositories/settings_repository.dart';
import '../../providers/car_mode_provider.dart';
import '../../providers/player_provider.dart';
import '../../providers/theme_provider.dart';
import '../../widgets/smart_artwork_image.dart';
import 'full_player_route.dart';
import 'mini_player.dart';

/// 二级页面悬浮播放器宿主（改版计划五；现已扩展到一级页面，见下）。
///
/// 包裹页面可滚动内容，监听滚动通知：向下滚动超过阈值收起为底部圆形
/// 唱片，向上滚动展开为圆角悬浮条。收起/展开状态用 [ValueNotifier] 驱动，
/// 只让悬浮播放器自身重建，不触发整页高频刷新。
///
/// **形态判定**：页面可无条件把 `Scaffold.body`（或整页）包进本组件，宿主
/// 自行决定是否渲染悬浮播放器——
/// - **一级页面**（路由栈底主布局内的 tab 页）与**二级页面**（push 出来的
///   路由）：渲染悬浮条，并给内容底部预留其高度。一级页面由 `_MainLayout`
///   统一包裹，且悬浮条接管后底部常驻 [MiniPlayer] 隐藏（避免两套播放器并存）；
/// - **桌面布局**：底部已有全宽 [NowPlayingBar]，直接透传内容；
/// - **沉浸态**（[SecondaryMiniPlayerHost.immersive]，封面流全屏浏览）：透传内容；
/// - **嵌套**：若上层已有一个正在承载悬浮条的宿主，则本层透传内容（幂等，
///   避免路由包裹 + 页面自包裹时出现双份悬浮条）。
///
/// 播放控制与「打开完整播放页」逻辑复用现有实现（[PlayerProvider] +
/// [openFullPlayer]）；悬浮条本身仅在有正在播放/暂停的歌曲时显示。
class SecondaryMiniPlayerHost extends StatefulWidget {
  const SecondaryMiniPlayerHost({
    super.key,
    required this.child,
    this.collapseThreshold = 24.0,
    this.immersive = false,
  });

  /// 页面内容（通常是可滚动列表 / CustomScrollView）。
  final Widget child;

  /// 触发收起/展开的累计滚动阈值（dp），避免轻微抖动误触发。
  final double collapseThreshold;

  /// 是否处于沉浸态（封面流横屏全屏浏览）。为 true 时不渲染悬浮条，
  /// 与底部常驻条在同一场景下隐藏的行为保持一致（见 `_MainLayout._buildBody`）。
  final bool immersive;

  @override
  State<SecondaryMiniPlayerHost> createState() =>
      _SecondaryMiniPlayerHostState();
}

class _SecondaryMiniPlayerHostState extends State<SecondaryMiniPlayerHost> {
  final ValueNotifier<bool> _collapsed = ValueNotifier<bool>(false);
  // 同向滚动累计位移；反向时清零，实现阈值滞回，防抖动。
  double _accum = 0.0;
  int _accumSign = 0;

  @override
  void dispose() {
    _collapsed.dispose();
    super.dispose();
  }

  bool _onScroll(ScrollNotification n) {
    if (n is ScrollUpdateNotification) {
      final d = n.scrollDelta ?? 0.0;
      if (d == 0) return false;
      final sign = d > 0 ? 1 : -1;
      if (sign != _accumSign) {
        _accum = 0.0;
        _accumSign = sign;
      }
      _accum += d;
      if (_accum > widget.collapseThreshold && !_collapsed.value) {
        _collapsed.value = true; // 向下浏览 → 收起
      } else if (_accum < -widget.collapseThreshold && _collapsed.value) {
        _collapsed.value = false; // 向上浏览 → 展开
      }
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    // 悬浮播放器总开关（设置页可关）：关闭时直渲染内容、不预留底部空间。
    // 用 ValueListenableBuilder 订阅全局开关，切换后各页宿主即时生效，
    // 不依赖上层重建。
    return ValueListenableBuilder<bool>(
      valueListenable: kSecondaryPlayerEnabled,
      builder: (context, playerEnabled, child) {
        // 沉浸态（封面流横屏全屏浏览）：不渲染任何播放器，保持全屏无遮挡
        // （此时 shell 也隐藏底部常驻条，见 _MainLayout._buildBody）。
        if (widget.immersive) return child!;
        // 开关是**播放器形态**选择，全局一致：
        // - 开：悬浮播放器（主页 + 二级页面，Pad 右下限宽）；
        // - 关：底部常驻播放条（主页由 shell 承载，二级页面由本宿主补上同一条），
        //   保证任何页面都有播放器、且两种形态下不出现两套并存。
        if (playerEnabled) return _buildHost(context, child!);
        return _buildBottomBarFallback(context, child!);
      },
      child: widget.child,
    );
  }

  /// 开关关闭时的回落形态：底部常驻播放条（与主页 shell 同一条 [MiniPlayer]）。
  ///
  /// 只在二级页面补上 —— 主页由 `_MainLayout` 的 shell 直接承载同一条，若此处
  /// 再渲染会出现两条，故按 `isSecondaryRoutePage` 区分。
  ///
  /// 放进 `Column`（真实布局空间）而非悬浮 `Stack`：MiniPlayer 占据的高度由
  /// 内容自动让位，无需再注入底部预留 padding，也与 shell 的承载方式同构。
  Widget _buildBottomBarFallback(BuildContext context, Widget child) {
    // 桌面布局：底部已有全宽 NowPlayingBar，透传即可。
    if (isDesktopLayout(context)) return child;
    // 幂等：上层宿主已承载时透传。
    if (_SecondaryPlayerHostScope.of(context)) return child;
    // 主页（一级页面）：shell 已渲染同一条，本宿主透传，避免双条。
    if (!isSecondaryRoutePage(context)) return child;

    return _SecondaryPlayerHostScope(
      child: Column(
        children: [
          Expanded(child: child),
          const MiniPlayer(),
        ],
      ),
    );
  }

  /// 真正决定是否渲染悬浮条与是否预留底部的分支（[build] 的承载层）。
  Widget _buildHost(BuildContext context, Widget child) {
    // 桌面布局：底部已有全宽 NowPlayingBar（见横屏平板重设计计划 4.6），
    // 二级悬浮播放器走空分支——直接渲染内容，不加悬浮唱片、不预留底部空间，
    // 避免三套播放器并存割裂。
    if (isDesktopLayout(context)) return child;

    // 幂等：上层已有正在承载悬浮条的宿主（如路由包裹 + 页面自包裹并存）时，
    // 本层退化为透传，避免嵌套出现双份悬浮条。
    if (_SecondaryPlayerHostScope.of(context)) return child;

    // 一级页面（路由栈底主布局内的 tab 页）现在同样走悬浮播放器：由 `_MainLayout`
    // 把页面主体包进本宿主，并同步隐藏底部常驻 MiniPlayer（app.dart `_buildBody`），
    // 避免出现两个播放器。故这里不再按 isSecondaryRoutePage 区分一/二级。

    // 悬浮播放器覆盖在内容之上（Stack），需给内容底部预留其高度，
    // 否则列表最后几项会被悬浮栏遮挡（见改版计划补充四）。
    // 通过注入 MediaQuery 底部 padding 让子树里按 MediaQuery.padding.bottom
    // 计算内边距的列表/ SafeArea 自动预留空间，无需逐页改。
    // 仅在有正在播放的歌曲时预留（无歌曲时悬浮栏不显示）。
    final hasSong = context.select<PlayerProvider, bool>(
      (p) => p.currentSong != null,
    );
    final carMode = context.select<CarModeProvider, bool>((p) => p.enabled);
    final reserve = (hasSong && !carMode) ? _kReservedBottom : 0.0;
    final mq = MediaQuery.of(context);
    // 标记本宿主正在承载悬浮条，供子树内的嵌套宿主检测后退化透传。
    return _SecondaryPlayerHostScope(
      child: NotificationListener<ScrollNotification>(
        onNotification: _onScroll,
        child: Stack(
          children: [
            Positioned.fill(
              child: MediaQuery(
                data: mq.copyWith(
                  padding: mq.padding.copyWith(
                    bottom: mq.padding.bottom + reserve,
                  ),
                ),
                child: child,
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: SecondaryMiniPlayer(
                collapsed: _collapsed,
                onRequestExpand: () => _collapsed.value = false,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 标记「上层已有一个正在承载悬浮条的 [SecondaryMiniPlayerHost]」的作用域。
///
/// 只在宿主真正渲染悬浮条时提供（一级页面 / 桌面 / 已被祖先承载时不提供），
/// 因此子树内的嵌套宿主一旦检测到本作用域即可安全退化为透传。
class _SecondaryPlayerHostScope extends InheritedWidget {
  const _SecondaryPlayerHostScope({required super.child});

  static bool of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<_SecondaryPlayerHostScope>() !=
      null;

  @override
  bool updateShouldNotify(_SecondaryPlayerHostScope oldWidget) => false;
}

/// 悬浮播放器高度（唱片/圆角条 64 + 底部内边距 12）：内容底部据此预留。
const double _kReservedBottom = 76.0;

double _lerp(double a, double b, double t) => a + (b - a) * t;

/// Pad 下悬浮播放器的**轨道最大宽度**（展开态胶囊宽）。
///
/// 手机上的可用宽度（视口 - 左右各 16）约 368dp，胶囊内 4 个元素（封面 /
/// 标题·艺人 / 播放暂停 / 切歌）的排布以此为基准，故 Pad 上取同量级的 400dp，
/// 既避免"横贯全屏的长条"，也不改变内部排布。
const double kSecondaryPlayerPadMaxWidth = 400.0;

/// 二级页面悬浮播放器本体（[MiniPlayer] 的二级悬浮模式）。
///
/// 展开态：扁平圆角悬浮条（封面 + 歌曲信息 + 播放控制 + 切歌，点击进
/// 完整播放页）。收起态：底部居中圆形唱片，封面随播放旋转，点击仅展开
/// 播放器。两态之间用圆角/尺寸/透明度连续过渡。
class SecondaryMiniPlayer extends StatefulWidget {
  const SecondaryMiniPlayer({
    super.key,
    required this.collapsed,
    required this.onRequestExpand,
  });

  final ValueListenable<bool> collapsed;
  final VoidCallback onRequestExpand;

  @override
  State<SecondaryMiniPlayer> createState() => _SecondaryMiniPlayerState();
}

class _SecondaryMiniPlayerState extends State<SecondaryMiniPlayer>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  // 形变进度：0=展开圆角条，1=收起圆盘（弹簧一次性过渡，保留 vsync）
  late final AnimationController _morph;
  // 唱片旋转：播放且卡片可见时由共享 60fps 节拍步进，暂停/不可见时停住保留角度
  late final AnimationController _spin;

  static const double _disc = 64.0;

  /// 全屏播放器展开到此进度时本卡片 opacity 已为 0（不可见）。
  static const double _kInvisibleExpansion = 0.99;

  /// 是否已挂在共享 60fps 帧驱动上。
  bool _boundToDriver = false;

  /// 由 build 计算出的「播放中 + 卡片可见」（含无歌 / 车机模式 / 全屏已展开）。
  bool _shouldSpin = false;

  /// TickerMode 是否被关闭（被不透明路由覆盖 / TabBarView 切走）。
  bool _tickerModeMuted = false;

  /// App 是否退到后台。
  bool _appSuspended = false;

  // —— 折叠态拖拽 + 吸附 ——
  /// 拖拽/吸附过程中的水平偏移（相对当前停靠位）。用 ValueNotifier 驱动
  /// Transform.translate，避免每帧 setState（铁律 40.2）。
  final ValueNotifier<double> _dragOffset = ValueNotifier<double>(0);
  /// 吸附动画（一次性 forward，禁 repeat —— 铁律 40.1）。
  late final AnimationController _snap;
  /// 吸附动画起点（松手时的残余偏移，动画中按曲线归零）。
  double _snapStartOffset = 0;
  /// 是否正在拖拽。
  bool _dragging = false;

  // 收起为圆盘时，环形进度/封面需要跟随唱片旋转。
  // 若把 _spin 直接驱动在动画链上：展开态旋转为 0（_spin.value*0），
  // 但 kAnimationListener 仍会被 controller 通知；而 FadeTransition 只是
  // 视觉 alpha=0，底座仍在布局，整个环每秒 12 次重建而无谓开销。

  /// 封面解码名义尺寸：取两态封面可见尺寸的最大值（展开 58），保证放大清晰；
  /// 实际可见尺寸由 raster 上的 Transform.scale 承担，解码尺寸恒定不重解码，
  /// 消除形变逐帧改尺寸导致的封面闪烁（旧实现的隐形 bug 源之一）。
  static const double _kCoverDecode = 58.0;

  @override
  void initState() {
    super.initState();
    _morph = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 320),
      value: widget.collapsed.value ? 1.0 : 0.0,
    );
    _spin = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 12),
    );
    widget.collapsed.addListener(_onCollapsedChanged);
    WidgetsBinding.instance.addObserver(this);
    _snap = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
    );
    // 吸附动画推进：残余偏移按 easeOutCubic 归零（Align 已切到新槽位，
    // 两者叠加的净效果即"圆盘滑向槽位"）。
    _snap.addListener(() {
      final t = Curves.easeOutCubic.transform(_snap.value);
      _dragOffset.value = _snapStartOffset * (1 - t);
    });
  }

  /// 共享 `Timer` 不受 `TickerMode` 约束（§10.3），必须自行同步挂起。
  ///
  /// 用 `TickerMode.valuesOf(context).enabled` 而非已弃用的 `TickerMode.of`
  /// （后者自 v3.35 起 deprecated）；`.enabled` 与旧 `of` 语义等价。
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final bool muted = !TickerMode.valuesOf(context).enabled;
    if (muted != _tickerModeMuted) {
      _tickerModeMuted = muted;
      _syncSpin();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final bool suspended = state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached;
    if (suspended == _appSuspended) return;
    _appSuspended = suspended;
    _syncSpin();
  }

  void _onCollapsedChanged() {
    // 用弹簧物理驱动形变，带轻微过冲，让圆角条↔圆盘的过渡更有生命感、更连贯。
    final target = widget.collapsed.value ? 1.0 : 0.0;
    _morph.animateWith(
      SpringSimulation(
        M3ExpressiveMotion.defaultSpring,
        _morph.value,
        target,
        _morph.velocity,
      ),
    );
  }

  /// 由 build / 展开进度回调整理出的"应当旋转"条件，收口到唯一入口。
  void _setShouldSpin(double expansion, bool isPlaying) {
    // 全屏播放器展开时本卡片 opacity=(1-exp)→0；[DraggablePlayerRoute] 是
    // `opaque => false`（full_player_route.dart:428），被它覆盖**不会**触发
    // TickerMode 关闭，故必须在此显式判定，否则「打开全屏播放器后悬浮唱片
    // 仍在不可见地旋转」——§10.4.3 最典型的漏电点。
    _shouldSpin = isPlaying && expansion < _kInvisibleExpansion;
    _syncSpin();
  }

  /// 唯一收口：仅在「播放中 + 可见 + 前台」时挂共享 60fps 节拍（幂等）。
  void _syncSpin() {
    final bool shouldRun = _shouldSpin && !_tickerModeMuted && !_appSuspended;
    if (shouldRun == _boundToDriver) return;
    if (shouldRun) {
      PlayerFrameDriver.instance.addListener(_onSpinTick);
    } else {
      PlayerFrameDriver.instance.removeListener(_onSpinTick);
    }
    _boundToDriver = shouldRun;
  }

  /// 共享节拍回调：按转一圈时长步进旋转值（0→1 循环）。
  ///
  /// 用步进 `.value` 而不是 `repeat()`：controller 的 Ticker 不会被启动，
  /// 帧生产由 16ms 共享定时器限制到 60fps（`repeat()` 会让 120Hz 屏整页
  /// 保持 120fps，见 AGENTS.md §10.1.1 / §10.4.1）。
  void _onSpinTick() {
    final int ms = _spin.duration?.inMilliseconds ?? 0;
    if (ms <= 0) return;
    _spin.value =
        (_spin.value + PlayerFrameDriver.step.inMilliseconds / ms) % 1.0;
  }

  /// 封面+环子树的绘制隔离层。
  /// 形变/旋转的中间帧只有本层外的 Transform 在动，内部封面/环不被逐帧
  /// 重绘（避免解码尺寸逐帧变化导致的封面闪烁）。
  final GlobalKey _coverRepaintKey = GlobalKey();

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.collapsed.removeListener(_onCollapsedChanged);
    if (_boundToDriver) {
      PlayerFrameDriver.instance.removeListener(_onSpinTick);
      _boundToDriver = false;
    }
    _snap.dispose();
    _dragOffset.dispose();
    _morph.dispose();
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerProvider>();
    final song = player.currentSong;
    // 注意：两条早退都必须先收口驱动，否则 `_shouldSpin` 会残留上一次的 true，
    // 表现为「已经不可见却仍在产帧」（§10.4.3）。
    if (song == null) {
      _setShouldSpin(0.0, false);
      return const SizedBox.shrink();
    }
    // 车机模式：播放器常驻侧边面板，任何界面都不显示悬浮播放器（沿用现有规则）。
    if (context.watch<CarModeProvider>().enabled) {
      _setShouldSpin(0.0, false);
      return const SizedBox.shrink();
    }
    _setShouldSpin(playerExpansion.value, player.isPlaying);
    final cs = Theme.of(context).colorScheme;
    final useBackgroundImage = context.watch<ThemeProvider>().useBackgroundImage;

    // 完整播放页展开时淡出（与底部常驻 MiniPlayer 同一 playerExpansion 规则）。
    return ValueListenableBuilder<double>(
      valueListenable: playerExpansion,
      builder: (context, exp, child) {
        // 展开/收起过程中重新收口：exp 变化不会触发本 widget 的 build。
        _setShouldSpin(exp, player.isPlaying);
        final opacity = (1.0 - exp).clamp(0.0, 1.0);
        return IgnorePointer(
          ignoring: exp > 0.5,
          child: Opacity(opacity: opacity, child: child),
        );
      },
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: LayoutBuilder(
            builder: (context, constraints) {
              // Pad（最短边 ≥600dp，`isPadLayout` 口径把横屏手机排除在外）：
              // 悬浮条不再横贯全屏 —— 轨道限宽到 [kSecondaryPlayerPadMaxWidth]
              // 并右下停靠。形变全程只在轨道内发生，收起/展开时封面不会横扫整屏。
              // 手机（含横屏）走原路径：轨道 = 可用宽度、底部居中，零变化。
              final bool pad = isPadLayout(context);
              final double trackW = pad
                  ? math.min(constraints.maxWidth, kSecondaryPlayerPadMaxWidth)
                  : constraints.maxWidth;
              // 停靠位驱动对齐：默认（启动装载后）手机=center、Pad=right；
              // 拖拽吸附后切换。展开态胶囊与折叠态圆盘共用同一停靠侧，
              // 形变过程中盒子始终朝停靠侧收拢，视觉连续。
              return ValueListenableBuilder<SecondaryPlayerDockSide>(
                valueListenable: kSecondaryPlayerDock,
                builder: (context, dock, _) => AnimatedBuilder(
                  animation: _morph,
                  builder: (context, _) => _buildMorph(
                    context,
                    player,
                    song,
                    cs,
                    trackW,
                    alignment: _dockAlignment(dock),
                    dock: dock,
                    trackW: trackW,
                    useBackgroundImage: useBackgroundImage,
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  /// 停靠位 → Align 对齐（折叠态圆盘与展开态胶囊共用同一停靠侧）。
  Alignment _dockAlignment(SecondaryPlayerDockSide side) {
    switch (side) {
      case SecondaryPlayerDockSide.left:
        return Alignment.bottomLeft;
      case SecondaryPlayerDockSide.center:
        return Alignment.bottomCenter;
      case SecondaryPlayerDockSide.right:
        return Alignment.bottomRight;
    }
  }

  /// 当前停靠位在轨道内的圆盘左缘基准（轨道内坐标，`0 .. trackW - _disc`）。
  double _dockBase(SecondaryPlayerDockSide side, double maxDx) {
    switch (side) {
      case SecondaryPlayerDockSide.left:
        return 0.0;
      case SecondaryPlayerDockSide.center:
        return maxDx / 2;
      case SecondaryPlayerDockSide.right:
        return maxDx;
    }
  }

  /// 水平拖拽 + 松手吸附。仅折叠态（[_morph] 过半）生效；垂直滚动事件
  /// 不被抢占（用水平手势识别器），手指在圆盘上上下滑仍可滚动页面。
  void _onDiscHorizontalDragStart(DragStartDetails details) {
    if (_morph.value < 0.5) return; // 展开态不可拖
    _dragging = true;
    _snap.stop();
  }

  void _onDiscHorizontalDragUpdate(DragUpdateDetails details, double trackW) {
    if (!_dragging) return;
    final double maxDx = trackW - _disc;
    final double base = _dockBase(kSecondaryPlayerDock.value, maxDx);
    _dragOffset.value =
        (_dragOffset.value + details.delta.dx).clamp(-base, maxDx - base);
  }

  void _onDiscHorizontalDragEnd(DragEndDetails details, double trackW) {
    if (!_dragging) return;
    _dragging = false;
    _snapToNearestSlot(trackW);
  }

  void _onDiscHorizontalDragCancel(double trackW) {
    if (!_dragging) return;
    _dragging = false;
    _snapToNearestSlot(trackW);
  }

  /// 松手吸附：取圆盘左缘与三槽位（左/中/右）的最近者，切换停靠位并把
  /// 残余偏移动画归零（Align 瞬移到新槽位 + 反相补偿 = "圆盘滑向槽位"）。
  void _snapToNearestSlot(double trackW) {
    final double maxDx = trackW - _disc;
    final slots = <double>[0.0, maxDx / 2, maxDx];
    final double x =
        _dockBase(kSecondaryPlayerDock.value, maxDx) + _dragOffset.value;

    var best = 0;
    var bestDist = double.infinity;
    for (var i = 0; i < slots.length; i++) {
      final dist = (slots[i] - x).abs();
      if (dist < bestDist) {
        bestDist = dist;
        best = i;
      }
    }
    final target = SecondaryPlayerDockSide.values[best];
    _snapStartOffset = x - slots[best];
    if (kSecondaryPlayerDock.value != target) {
      kSecondaryPlayerDock.value = target;
      unawaited(
        SettingsRepository().setSecondaryPlayerDockRaw(target.name),
      );
    }
    _snap
      ..stop()
      ..forward(from: 0);
  }

  /// [fullW] 是**轨道宽度**（Pad 下已按 [kSecondaryPlayerPadMaxWidth] 限宽）；
  /// [alignment] 由 [kSecondaryPlayerDock] 停靠位驱动（默认手机中下 / Pad 右下，
  /// 拖拽吸附后跟随切换），折叠态圆盘与展开态胶囊共用同一停靠侧。
  Widget _buildMorph(
    BuildContext context,
    PlayerProvider player,
    dynamic song,
    ColorScheme cs,
    double fullW, {
    Alignment alignment = Alignment.bottomCenter,
    SecondaryPlayerDockSide dock = SecondaryPlayerDockSide.center,
    double trackW = 0,
    bool useBackgroundImage = false,
  }) {
    // 弹簧可能轻微过冲到 [0,1] 之外；几何取值 clamp，过冲仅体现在时间曲线上。
    final t = _morph.value.clamp(0.0, 1.0);
    final w = _lerp(fullW, _disc, t);
    // 展开态圆角 == 高度一半 → 两侧呈半圆（胶囊形），始终与专辑封面贴合。
    final radius = _disc / 2;
    // 文字/按钮在前 60% 行程内淡出，收起后完全让位给圆盘。
    final textOpacity = (1.0 - t / 0.6).clamp(0.0, 1.0);
    // —— 贯穿两态的封面（唯一贯穿两态的元素）——
    // 封面容器恒为 _disc(64)×_disc：展开态填满胶囊条高度（封面即主视觉，
    // 封面更大），收起态即为圆盘本体。只在水平方向从左缘平移到条中心：
    //   展开 left=2（贴左，留 2 与胶囊左缘）；收起 w=64 → left=0（居中）。
    //   中间帧 w>64，(w-64)/2 让圆盘随条收拢自然居中（见改版计划补充五）。
    // 封面是唯一视觉焦点，不叠加彩色进度环。
    final coverLeft = _lerp(2.0, (w - _disc) / 2, t);

    return Align(
      alignment: alignment,
      child: ValueListenableBuilder<double>(
        valueListenable: _dragOffset,
        builder: (context, dx, child) => Transform.translate(
          offset: Offset(dx, 0),
          child: child,
        ),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragStart: _onDiscHorizontalDragStart,
          onHorizontalDragUpdate: (d) => _onDiscHorizontalDragUpdate(d, trackW),
          onHorizontalDragEnd: (d) => _onDiscHorizontalDragEnd(d, trackW),
          onHorizontalDragCancel: () => _onDiscHorizontalDragCancel(trackW),
          onTap: () {
            AppHaptics.click();
            if (_morph.value > 0.5) {
              widget.onRequestExpand(); // 收起态：点击只展开
            } else {
              openFullPlayer(context); // 展开态：点击进完整播放页
            }
          },
          child: Material(
            elevation: 0,
            color: useBackgroundImage
                ? cs.surface.withValues(alpha: 0.80)
                : cs.surfaceContainerLow,
            borderRadius: BorderRadius.circular(radius),
            clipBehavior: Clip.antiAlias,
            child: SizedBox(
              width: w,
              height: _disc,
              child: Stack(
                children: [
                // 文字信息 + 播放控制：随宽度收缩淡出，用 OverflowBox 保持
                // 全宽布局，收缩过程只裁剪不重排，避免文字挤压跳动。
                if (textOpacity > 0.01)
                  Positioned.fill(
                    child: IgnorePointer(
                      ignoring: t > 0.4,
                      child: Opacity(
                        opacity: textOpacity,
                        child: OverflowBox(
                          minWidth: 0,
                          maxWidth: fullW,
                          alignment: Alignment.centerLeft,
                          child: SizedBox(
                            width: fullW,
                            child: _expandedRow(context, player, song, cs, t),
                          ),
                        ),
                      ),
                    ),
                  ),
                // 贯穿两态的封面：从左缘平移到中心。
                Positioned(
                  left: coverLeft,
                  top: 0,
                  width: _disc,
                  height: _disc,
                  child: _cover(song, t),
                ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 展开态的文字信息 + 播放控制（封面已抽为贯穿两态的独立元素，故此处
  /// 左侧留出封面空位）。点击整体进完整播放页（由外层 GestureDetector 处理）。
  ///
  /// 左侧让位宽度 ≈ 封面容器右缘：封面容器恒 64、展开 left=2 → 右缘 ≈ 66；
  /// 文字在 t<0.6 期间淡出且 IgnorePointer，让位宽度内插即可，无排版跳动。
  Widget _expandedRow(
    BuildContext context,
    PlayerProvider player,
    dynamic song,
    ColorScheme cs,
    double t,
  ) {
    // 封面容器右缘 ≈ 66（展开）→ 64（收起 left=0）：文字左内边距随之内插。
    final leftPad = _lerp(66.0, 64.0, t);
    return Padding(
      // 左侧让位给封面+环（环右缘≈66→64），右侧常规内边距。
      padding: EdgeInsets.fromLTRB(leftPad, 0, 10, 0),
      child: Row(
        children: [
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Text(
                  song.displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                Text(
                  song.artist,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: cs.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: Icon(player.isPlaying ? Icons.pause : Icons.play_arrow),
            onPressed: () {
              AppHaptics.click();
              if (player.isPlaying) {
                player.pause();
              } else {
                player.resume();
              }
            },
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.skip_next),
            onPressed: () {
              AppHaptics.click();
              player.next();
            },
          ),
        ],
      ),
    );
  }

  /// 贯穿两态的封面（+ 收起态圆环）。容器恒为 [_disc]×[_disc]。
  ///
  /// **进度指示按状态二选一**（消除旧实现展开态「胶囊环 + 封面圆环」双环）：
  /// - 展开态 t=0：圆环完全透明，进度只由外层胶囊环表达，封面更大更干净；
  /// - 收起态 t→1：圆环淡入到圆盘外圈，封面缩出留白并随播放旋转。
  ///
  /// **抗闪烁**：`SmartArtworkImage` 的 `size`/`borderRadius`/decode 恒为
  /// [_kCoverDecode]，ImageCache key 不随形变变化；封面可见尺寸的变化只由
  /// raster 上的 `Transform.scale` 承担，不触发重解码。
  Widget _cover(dynamic song, double t) {
    final coverVisible = _lerp(58.0, 56.0, t);
    final coverScale = coverVisible / _kCoverDecode;

    return RepaintBoundary(
      key: _coverRepaintKey,
      child: SizedBox(
        width: _disc,
        height: _disc,
        child: Transform.scale(
          scale: coverScale,
          child: AnimatedBuilder(
            animation: _spin,
            builder: (context, _) => Transform.rotate(
              // 旋转随过渡逐渐加深：t=0（展开）不转、t=1（圆盘）全速。
              angle: _spin.value * 2 * math.pi * t,
              child: ClipOval(
                child: SmartArtworkImage(
                  artworkUri: song.artworkUri,
                  fallbackFilePath: song.localPath,
                  songId: song.id,
                  size: _kCoverDecode,
                  borderRadius: _kCoverDecode / 2,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
