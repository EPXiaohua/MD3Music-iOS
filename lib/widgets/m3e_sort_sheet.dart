import 'package:m3e_core/m3e_core.dart';
import 'package:material_ui/material_ui.dart';

/// 一个排序选项：值 + 显示文本。
typedef M3ESortOption<T> = ({T value, String label});

/// 顶栏排序触发器：外观是一个图标，点一下 M3E 下拉面板就在图标下方就近展开。
///
/// 交互与原 PopupMenu 一致（但少了一次点击）：
/// - 点未选中的项 → 切换排序项（[onPicked] 的 repeated 为 false）
/// - 再次点当前项 → M3E 单选会把当前项取消选中，回调收到空列表，
///   这里映射为切换升/降序（[onPicked] 的 repeated 为 true）
///
/// ## 为什么要用 [OverflowBox] 撑宽
/// `M3EDropdownMenu` 的面板宽度**硬绑定字段宽度**（内部是
/// `SizedBox(width: 字段渲染宽度)`），而字段本身又是拉起/收起面板的唯一触发器
/// （外点关闭层会主动跳过落在字段范围内的点击，所以「隐藏的 0 尺寸字段 + 旁边放
/// 一个 IconButton」会导致点第二次收不起来）。于是这里让字段的真实渲染宽度 =
/// [_panelWidth]（够放条目文字），再用 [OverflowBox] 把它塞回顶栏一个 [_slot]
/// 见方的图标位：多出来的宽度从左侧溢出，完全透明、也不可点（[OverflowBox]
/// 只对自身尺寸范围做命中测试），图标（[M3EDropdownFieldStyle.suffixIcon]）
/// 正好落在图标位中心，顶栏排布与原来的 IconButton 完全一致。
class M3ESortButton<T> extends StatefulWidget {
  /// Tooltip 文案，同时用作字段的无障碍标签。
  final String tooltip;

  /// 触发器图标。
  final IconData icon;

  /// 排序选项（值 + 显示文本）。
  final List<M3ESortOption<T>> options;

  /// 当前生效的排序项，必须能在 [options] 中找到。
  final T current;

  /// 选中回调。`repeated` 为 true 表示「再次点了当前项」（用于翻转升/降序）。
  final void Function(T value, bool repeated) onPicked;

  const M3ESortButton({
    super.key,
    this.tooltip = '排序',
    this.icon = Icons.sort,
    required this.options,
    required this.current,
    required this.onPicked,
  });

  @override
  State<M3ESortButton<T>> createState() => _M3ESortButtonState<T>();
}

class _M3ESortButtonState<T> extends State<M3ESortButton<T>> {
  /// 在顶栏里实际占位的尺寸：与 IconButton 的 48×48 一致，前后图标不位移。
  static const double _slot = 48;

  /// 字段与面板的真实宽度：够放最长条目文字（默认 itemPadding 16×2 + 选中勾选 20）。
  static const double _panelWidth = 220;

  late final M3EDropdownController<T> _controller;

  @override
  void initState() {
    super.initState();
    _controller = M3EDropdownController<T>();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 选择变化回调。
  ///
  /// 上游只在挂载（或换 controller）时登记该回调一次，所以这里必须读
  /// `widget.xxx` 取实时值，不能捕获 build 时的局部变量。
  void _handleSelectionChanged(List<M3EDropdownItem<T>> selected) {
    if (selected.isEmpty) {
      // 再次点当前项：单选下当前项被取消选中 → 空列表 → 翻转升/降序
      widget.onPicked(widget.current, true);
      return;
    }
    final value = selected.first.value;
    if (value == widget.current) {
      // 回调值与组件声明的当前值一致：这是上游 setItems 的回灌
      // （父级每次重建都会经 didUpdateWidget → setItems 触发一次），
      // 不是用户操作，必须忽略，否则排序方向会被反复翻转。
      // 用户真正「再点当前项」走的是上面的空列表分支。
      return;
    }
    widget.onPicked(value, false);
  }

  /// 图标取色：与相邻 IconButton 的规则保持一致。
  ///
  /// IconButton 的规则是「环境 IconTheme 有非默认色就用它（顶栏里就是 AppBar
  /// 注入的 foregroundColor），否则回落到 onSurfaceVariant」；裸 Icon 直接用
  /// 环境色，在非顶栏场景（如本地音乐页的工具栏）会比相邻 IconButton 偏黑。
  Color _iconColor(BuildContext context) {
    final theme = Theme.of(context);
    final ambient = IconTheme.of(context).color;
    final isDefaultAmbient = ambient == null ||
        ambient ==
            (theme.brightness == Brightness.dark
                ? Colors.white
                : Colors.black87);
    return isDefaultAmbient ? theme.colorScheme.onSurfaceVariant : ambient;
  }

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.tooltip,
      child: SizedBox(
        width: _slot,
        height: _slot,
        child: OverflowBox(
          // 只放开宽度：字段（连带面板）的真实宽度 = _panelWidth
          minWidth: _panelWidth,
          maxWidth: _panelWidth,
          minHeight: _slot,
          maxHeight: _slot,
          // 字段与图标位右对齐：图标留在图标位内，多出的宽度从左侧溢出
          alignment: Alignment.centerRight,
          child: M3EDropdownMenu<T>(
            controller: _controller,
            items: [
              for (final option in widget.options)
                M3EDropdownItem<T>(
                  label: option.label,
                  value: option.value,
                  selected: option.value == widget.current,
                ),
            ],
            singleSelect: true,
            showChipAnimation: false,
            onSelectionChanged: _handleSelectionChanged,
            // 字段里不显示任何文字，外观只由 suffixIcon 提供
            selectedItemBuilder: (_) => const SizedBox.shrink(),
            fieldStyle: M3EDropdownFieldStyle(
              hintText: widget.tooltip,
              backgroundColor: Colors.transparent,
              // foregroundColor 同时是按压/悬停高亮色，置为透明，
              // 否则 220 宽的字段会在顶栏闪出一条高亮条
              foregroundColor: Colors.transparent,
              border: BorderSide.none,
              focusedBorder: BorderSide.none,
              // 字段比图标位宽，键盘聚焦时的高亮环同样不需要
              focusRingWidth: 0,
              showArrow: false,
              // 用 suffixIcon 而非 prefixIcon：字段比图标位宽，
              // 只有右端对齐时图标才会落在图标位正中心
              suffixIcon: Icon(
                widget.icon,
                size: 24,
                color: _iconColor(context),
              ),
              // 排序图标不该随面板开合旋转
              animateSuffixIcon: false,
              // 12 内边距 + 24 图标 = 48，与图标位等高，图标垂直居中
              padding: const EdgeInsets.all(12),
            ),
          ),
        ),
      ),
    );
  }
}
