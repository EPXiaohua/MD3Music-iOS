import 'package:material_ui/material_ui.dart';

import '../../data/repositories/settings_repository.dart';
import '../../widgets/resizable_splitter.dart';

/// 混合导航分派与双栏 Master-Detail（横屏平板重设计计划 4.4 B）。
///
/// - [AdaptiveNav.openDetail]：详情入口的统一分派——处于双栏 [DetailPaneScope]
///   内（横屏平板 B 类页面）则 push 进右侧详情面板的嵌套 Navigator；否则退回
///   [Navigator.push]（中央内容导航 A 类 / 手机整屏，行为完全不变）。
/// - [DesktopTwoPane]：把一个「主列表」页装进左窄列 + 可拖拽分隔条 + 右侧详情
///   面板（嵌套 Navigator，初始为空态占位）。仅在桌面布局的 B 类 Tab 使用。

/// 详情面板作用域：由 [DesktopTwoPane] 注入，[AdaptiveNav.openDetail] 据此
/// 找到右侧详情面板的 Navigator。用 InheritedWidget 传递而非全局单例，天然
/// 支持多个双栏 Tab 各自独立的详情栈。
class DetailPaneScope extends InheritedWidget {
  const DetailPaneScope({
    super.key,
    required this.detailKey,
    this.history,
    required super.child,
  });

  final GlobalKey<NavigatorState> detailKey;

  /// 该详情面板的前进历史（外壳注入，供工具栏「前进」）。
  final ForwardHistory? history;

  /// 查最近的详情面板 Navigator key（不建立重建依赖）。
  static GlobalKey<NavigatorState>? maybeOf(BuildContext context) {
    return _maybeOf(context)?.detailKey;
  }

  /// 查最近的详情面板前进历史（不建立重建依赖）。
  static ForwardHistory? historyOf(BuildContext context) {
    return _maybeOf(context)?.history;
  }

  static DetailPaneScope? _maybeOf(BuildContext context) {
    final el =
        context.getElementForInheritedWidgetOfExactType<DetailPaneScope>();
    return el?.widget as DetailPaneScope?;
  }

  @override
  bool updateShouldNotify(DetailPaneScope old) =>
      detailKey != old.detailKey || history != old.history;
}

/// 详情面板的「前进」历史栈（计划 4.3 顶部工具栏前进/后退）。
///
/// 记录被「后退」弹出的详情页构建器，以便工具栏「前进」原样重建。仅覆盖经
/// [AdaptiveNav.openDetail] 进入详情面板的导航（该处会给路由打上
/// [ForwardTag] 供观察者在 pop 时回收 builder）。新的正向导航（非重放）会
/// 清空前进栈，符合浏览器式前进/后退语义。
class ForwardHistory extends ChangeNotifier {
  final List<WidgetBuilder> _stack = [];

  /// 正在重放前进项时置真：抑制观察者把这次 push 误判为「新导航」而清栈。
  bool replaying = false;

  /// 程序化复位详情栈（切 Tab）时置真：抑制把复位 pop 记进前进栈。
  bool suppressRecord = false;

  bool get canGoForward => _stack.isNotEmpty;

  /// 记录一次「后退」弹出的详情页。
  void recordBack(WidgetBuilder builder) {
    if (suppressRecord) return;
    _stack.add(builder);
    notifyListeners();
  }

  /// 取出下一个「前进」目标（无则 null）。
  WidgetBuilder? takeNext() {
    if (_stack.isEmpty) return null;
    final b = _stack.removeLast();
    notifyListeners();
    return b;
  }

  /// 正向导航发生：清空前进栈。
  void invalidate() {
    if (_stack.isEmpty) return;
    _stack.clear();
    notifyListeners();
  }
}

/// 路由标签：携带该详情路由的构建器，供前进历史在 pop 时回收重建。
class ForwardTag {
  const ForwardTag(this.builder);
  final WidgetBuilder builder;
}

/// 详情导航分派入口。各 B 类页面的详情入口把
/// `Navigator.push(context, MaterialPageRoute(builder: b))` 改为
/// `AdaptiveNav.openDetail(context, b)` 即可，无需自行判断布局。
class AdaptiveNav {
  const AdaptiveNav._();

  static Future<T?> openDetail<T>(
    BuildContext context,
    WidgetBuilder builder,
  ) {
    final scope = DetailPaneScope._maybeOf(context);
    final detailNav = scope?.detailKey.currentState;
    if (detailNav != null) {
      // 进入详情面板：打标签供前进历史回收；正向导航清空既有前进栈。
      final history = scope?.history;
      if (history != null && !history.replaying) history.invalidate();
      return detailNav.push(
        MaterialPageRoute<T>(
          builder: builder,
          settings: RouteSettings(arguments: ForwardTag(builder)),
        ),
      );
    }
    // 中央内容导航（桌面 A 类）：最近的 Navigator 即当前 Tab 的中央栈；
    // 手机 / 竖屏：根 Navigator。两种情况都走 Navigator.push，行为不变。
    return Navigator.of(context).push(MaterialPageRoute<T>(builder: builder));
  }
}

/// 双栏 Master-Detail 容器：左侧主列表 + 可拖拽分隔条 + 右侧详情面板。
///
/// [detailKey]/[detailObservers] 由外壳（[DesktopShell]）注入，使工具栏返回键
/// 与系统返回能作用于详情面板栈；未注入时内部自建 key（独立使用场景）。
class DesktopTwoPane extends StatefulWidget {
  const DesktopTwoPane({
    super.key,
    required this.master,
    this.detailKey,
    this.detailObservers = const [],
    this.history,
    this.emptyState,
  });

  /// 左侧主列表页（通常是原 Tab 页，如收藏 / 本地乐库）。
  final Widget master;

  /// 详情面板 Navigator key（外壳注入以驱动返回键）。
  final GlobalKey<NavigatorState>? detailKey;

  /// 详情面板 Navigator 观察者（外壳注入 ToolbarSync 以刷新返回键可用态）。
  final List<NavigatorObserver> detailObservers;

  /// 详情面板前进历史（外壳注入，供工具栏「前进」）。
  final ForwardHistory? history;

  /// 详情为空时的占位（默认居中提示）。
  final Widget? emptyState;

  @override
  State<DesktopTwoPane> createState() => _DesktopTwoPaneState();
}

class _DesktopTwoPaneState extends State<DesktopTwoPane> {
  static const double _kMinMaster = 280.0;
  static const double _kMaxMaster = 560.0;
  static const double _kDefaultFraction = 0.34;

  final SettingsRepository _settings = SettingsRepository();
  late final GlobalKey<NavigatorState> _detailKey =
      widget.detailKey ?? GlobalKey<NavigatorState>();

  double _masterFraction = _kDefaultFraction;
  double _lastTotalWidth = 1200.0;

  @override
  void initState() {
    super.initState();
    _loadRatio();
  }

  Future<void> _loadRatio() async {
    final r = await _settings.getDesktopDetailRatio();
    if (!mounted || r == null) return;
    setState(() => _masterFraction = r.clamp(0.15, 0.6));
  }

  void _onDelta(double dx) {
    setState(() {
      final master = (_masterFraction * _lastTotalWidth + dx)
          .clamp(_kMinMaster, _kMaxMaster);
      _masterFraction = (master / _lastTotalWidth).clamp(0.0, 1.0);
    });
  }

  void _persist() {
    // ignore: discarded_futures
    _settings.setDesktopDetailRatio(_masterFraction);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        _lastTotalWidth = c.maxWidth;
        final masterW =
            (_masterFraction * c.maxWidth).clamp(_kMinMaster, _kMaxMaster);
        return DetailPaneScope(
          detailKey: _detailKey,
          history: widget.history,
          child: Row(
            children: [
              SizedBox(width: masterW, child: widget.master),
              ResizableSplitter(onDelta: _onDelta, onDragEnd: _persist),
              Expanded(
                child: Navigator(
                  key: _detailKey,
                  observers: widget.detailObservers,
                  onGenerateRoute: (s) => MaterialPageRoute(
                    settings: s,
                    builder: (_) =>
                        widget.emptyState ?? const DetailEmptyState(),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// 详情面板空态占位（未选中任何项时）。
///
/// 桌面外壳（[DesktopTwoPane]）与设置页 Pad 双列共用。默认参数保持
/// 桌面外壳原行为；[icon]/[text] 可定制文案与图标，[color] 覆盖背景色
/// （null = surface；悬浮于壁纸之上的页面传 [Colors.transparent]）。
class DetailEmptyState extends StatelessWidget {
  const DetailEmptyState({
    super.key,
    this.icon = Icons.library_music_outlined,
    this.text = '从左侧选择一项查看详情',
    this.color,
  });

  final IconData icon;
  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: color ?? cs.surface,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 56, color: cs.onSurfaceVariant),
            const SizedBox(height: 12),
            Text(
              text,
              style: Theme.of(context)
                  .textTheme
                  .bodyLarge
                  ?.copyWith(color: cs.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}
