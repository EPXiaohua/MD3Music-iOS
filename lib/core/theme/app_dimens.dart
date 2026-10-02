import 'package:material_ui/material_ui.dart';

/// 全局尺寸设计 token（间距 / 圆角 / 布局约束）。
///
/// 目标：把散落在各页面的行内魔法数字（`EdgeInsets.all(16)`、
/// `SizedBox(height: 12)`、`BorderRadius.circular(8)`…）收敛到一套**等比**尺度，
/// 让间距、圆角、留白节奏在全项目一致、可扫描、可整体调整。
///
/// 设计理念：
/// - **4dp 基准、8dp 节奏**（8pt grid，允许 4dp 半档）。所有值都落在 4 的倍数上，
///   避免 6 / 10 / 14 / 18 这类离格值造成的视觉抖动。
/// - **语义命名**（xs / sm / md / lg / xl…）而非裸数字：迁移时强制在有限档位里
///   做选择，天然收敛不一致。
/// - **纯 dp**：全局「显示大小」由 [DisplayScaleScope]（ui_density.dart）统一缩放，
///   token 一律写裸 dp，不要在这里做任何缩放。
///
/// 迁移约定：`EdgeInsets.all(16)` → `EdgeInsets.all(AppSpacing.lg)`；
/// `SizedBox(height: 12)` → `const Gap(AppSpacing.md)` 或 `SizedBox(height: AppSpacing.md)`。
class AppSpacing {
  AppSpacing._();

  /// 0dp —— 显式表达"无间距"，比裸 0 更有意图。
  static const double none = 0;

  /// 2dp —— 极小间距：图标与文字、徽标内缩等。
  static const double xxs = 2;

  /// 4dp —— 基准单位：紧凑元素间的最小呼吸。
  static const double xs = 4;

  /// 8dp —— 小间距：列表项内垂直间距、chip 间距。
  static const double sm = 8;

  /// 12dp —— 中小间距：卡片内边距、段内元素间距。
  static const double md = 12;

  /// 16dp —— 标准间距：页面左右边距、Section 内边距（默认首选值）。
  static const double lg = 16;

  /// 24dp —— 大间距：Section 之间、主要内容块的分隔。
  static const double xl = 24;

  /// 32dp —— 超大间距：页面顶部留白、主要分区之间的强分隔。
  static const double xxl = 32;

  /// 48dp —— 巨大间距：空状态居中留白、大屏分区。
  static const double xxxl = 48;
}

/// 圆角 token，对齐 Material 3 shape scale（extra-small 4 → extra-large 28）。
///
/// 迁移约定：`BorderRadius.circular(8)` → `AppRadius.smAll`（或 `AppRadius.sm`
/// 在需要 double 的场景）。
class AppRadius {
  AppRadius._();

  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 28;

  /// 胶囊 / 全圆角（配合 [StadiumBorder] 或极大半径）。
  static const double full = 999;

  static const BorderRadius xsAll = BorderRadius.all(Radius.circular(xs));
  static const BorderRadius smAll = BorderRadius.all(Radius.circular(sm));
  static const BorderRadius mdAll = BorderRadius.all(Radius.circular(md));
  static const BorderRadius lgAll = BorderRadius.all(Radius.circular(lg));
  static const BorderRadius xlAll = BorderRadius.all(Radius.circular(xl));
}

/// 大屏 / 平板布局约束 token。
///
/// 「重组而非拉伸」原则：宽屏下不让内容行 / 文本无脑撑满，而是约束到一个
/// 可读宽度并居中，多出来的宽度用于分栏或留白。
class AppLayout {
  AppLayout._();

  /// 单栏内容的最大宽度：超过它就居中留白，而不是继续拉长（如设置项、表单、
  /// 单列列表在平板上的表现）。约等于 MD3 body pane 上限。
  static const double maxContentWidth = 840;

  /// 正文文本的舒适阅读宽度上限（歌词、长段描述），约 60–75 字符行长。
  static const double readableMaxWidth = 640;

  /// 网格每列的目标宽度（配合 [gridColumnsForWidth]）。
  static const double gridTargetExtent = 200;

  /// 双列（列表-详情）左列固定宽度。M3 list-detail master pane 推荐 280–300dp。
  static const double twoPaneMasterWidth = 300;

  /// 双列右列内容的最大宽度：超过就居中留白，与 [maxContentWidth] 同一
  /// 「重组而非拉伸」原则（约等于 MD3 body pane 在双列下的舒适上限）。
  static const double twoPaneDetailMaxWidth = 720;
}

/// 等距方形间隔组件，替代裸 `SizedBox(height: x)` / `SizedBox(width: x)`。
///
/// 同时设置宽高为 [extent]，在 [Column] 与 [Row] 中都能正确撑出间距
/// （Flex 交叉轴方向的固定尺寸无副作用）。需要非方形间隔时仍直接用 `SizedBox`。
class Gap extends StatelessWidget {
  const Gap(this.extent, {super.key});

  final double extent;

  @override
  Widget build(BuildContext context) => SizedBox(width: extent, height: extent);
}
