import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/modules/settings/lyric_animation_settings_page.dart';
import 'package:md3music/widgets/apple_lyrics/layout/lyric_preferences.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 歌词动画设置页的「恢复本页默认值」按钮测试。
///
/// 锁定两条契约：
/// 1. 二次确认点「恢复默认」后，本页全部参数回到默认值；
/// 2. 点「取消」什么都不动。
///
/// 注意：**绝不能**断言 `LyricPreferences.reset()` 的效果——按钮的实现
/// 刻意逐参数恢复，避免把字号/行距/辉光等不在本页的设置一并清掉。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    addTearDown(() => LyricPreferences.instance.reset());
  });

  Future<void> pumpPage(WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: LyricAnimationSettingsPage()),
    );
    await tester.pumpAndSettle();
  }

  /// 把本页 8 个参数全部设成非默认值（错峰起点开关设为 false）。
  Future<void> setAllNonDefault() async {
    final prefs = LyricPreferences.instance;
    await prefs.setInactiveScale(0.9);
    await prefs.setAlignPosition(0.5);
    await prefs.setLiftHeightPx(8.0);
    await prefs.setCascadeMaxDelayMs(300);
    await prefs.setCascadeBaseStepMs(120);
    await prefs.setCascadeDecayX(1.5);
    await prefs.setStaggerFromCurrentLine(false);
    // 字内渐变默认 sweep → 非默认取 classic
    await prefs.setFillMode(LyricFillMode.classic);
    // 辉光判定默认 fixed → 非默认取 adaptive
    await prefs.setGlowThresholdMode(GlowThresholdMode.adaptive);
    // 动态颜色混色比例默认 0.15 → 非默认取 0.5
    await prefs.setDynamicColorMixRatio(0.5);
    // 辉光强度默认 1.0 → 非默认取 1.6（滑块仅辉光开关开启时显示）
    await prefs.setUseGlowEffect(true);
    await prefs.setGlowIntensity(1.6);
  }

  /// 断言 8 个参数 + 错峰起点开关 + 字内渐变样式全部等于默认值。
  void expectAllDefaults() {
    final prefs = LyricPreferences.instance;
    expect(prefs.inactiveScale, equals(LyricPreferences.defaultInactiveScale));
    expect(prefs.alignPosition,
        equals(LyricPreferences.defaultAlignPositionForCurrentPlatform));
    expect(prefs.liftHeightPx,
        equals(LyricPreferences.defaultLiftHeightPxForCurrentPlatform));
    expect(prefs.cascadeMaxDelayMs,
        equals(LyricPreferences.defaultCascadeMaxDelayMsForCurrentPlatform));
    expect(prefs.cascadeBaseStepMs,
        equals(LyricPreferences.defaultCascadeBaseStepMsForCurrentPlatform));
    expect(prefs.cascadeDecayX, equals(LyricPreferences.defaultCascadeDecayX));
    expect(prefs.staggerFromCurrentLine,
        equals(LyricPreferences.defaultStaggerFromCurrentLine));
    expect(prefs.fillMode, equals(LyricFillMode.sweep));
    expect(prefs.glowThresholdMode, equals(GlowThresholdMode.fixed));
    expect(prefs.dynamicColorMixRatio,
        equals(LyricPreferences.defaultDynamicColorMixRatio));
    expect(prefs.glowIntensity,
        equals(LyricPreferences.defaultGlowIntensity));
  }

  /// 断言 8 个参数 + 开关 + 字内渐变样式仍是非默认值（用于取消路径）。
  void expectAllNonDefault() {
    final prefs = LyricPreferences.instance;
    expect(prefs.inactiveScale, equals(0.9));
    expect(prefs.alignPosition, equals(0.5));
    expect(prefs.liftHeightPx, equals(8.0));
    expect(prefs.cascadeMaxDelayMs, equals(300.0));
    expect(prefs.cascadeBaseStepMs, equals(120.0));
    expect(prefs.cascadeDecayX, equals(1.5));
    expect(prefs.staggerFromCurrentLine, isFalse);
    expect(prefs.fillMode, equals(LyricFillMode.classic));
    expect(prefs.glowThresholdMode, equals(GlowThresholdMode.adaptive));
    expect(prefs.dynamicColorMixRatio, equals(0.5));
    expect(prefs.glowIntensity, equals(1.6));
  }

  group('AppBar 重置按钮（恢复本页默认值）', () {
    testWidgets('二次确认点「恢复默认」：本页全部参数回到默认', (tester) async {
      await pumpPage(tester);
      await setAllNonDefault();
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.restart_alt));
      await tester.pumpAndSettle();
      // 二次确认对话框出现
      expect(find.text('恢复本页默认值'), findsOneWidget);

      await tester.tap(find.text('恢复默认'));
      await tester.pumpAndSettle();

      expectAllDefaults();
    });

    testWidgets('二次确认点「取消」：所有参数保持不变', (tester) async {
      await pumpPage(tester);
      await setAllNonDefault();
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.restart_alt));
      await tester.pumpAndSettle();
      expect(find.text('恢复本页默认值'), findsOneWidget);

      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      expectAllNonDefault();
    });

    testWidgets('重置按钮只动本页参数：字号/行距不受影响', (tester) async {
      await pumpPage(tester);
      await setAllNonDefault();
      // 本页之外的参数（字号/行距）预先设成非默认，验证重置不碰它们
      final prefs = LyricPreferences.instance;
      await prefs.setFontSize(33);
      await prefs.setLineSpacing(1.2);
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.restart_alt));
      await tester.pumpAndSettle();
      await tester.tap(find.text('恢复默认'));
      await tester.pumpAndSettle();

      expectAllDefaults();
      expect(prefs.fontSize, equals(33.0)); // 不在本页 → 不被重置
      expect(prefs.lineSpacing, equals(1.2));
    });

    testWidgets('错峰起点开关：切换即写入偏好', (tester) async {
      await pumpPage(tester);
      // 默认开启
      expect(LyricPreferences.instance.staggerFromCurrentLine, isTrue);

      // 开关位于 ListView 末尾，测试视口（800×600）折线以下不构建，先滚进来。
      // scrollUntilVisible 后中心点可能仍差几像素落在视口外（tap 落空），
      // 再用 ensureVisible 对齐到视口内。
      await tester.scrollUntilVisible(find.text('错峰从当前行上方开始'), 300);
      await tester.ensureVisible(find.text('错峰从当前行上方开始'));
      await tester.pumpAndSettle();
      expect(find.text('错峰从当前行上方开始'), findsOneWidget);

      await tester.tap(find.text('错峰从当前行上方开始'));
      await tester.pumpAndSettle();
      expect(LyricPreferences.instance.staggerFromCurrentLine, isFalse);

      await tester.tap(find.text('错峰从当前行上方开始'));
      await tester.pumpAndSettle();
      expect(LyricPreferences.instance.staggerFromCurrentLine, isTrue);
    });

    testWidgets('字内渐变样式：切换即写入偏好，再切换回扫光', (tester) async {
      await pumpPage(tester);
      // 默认扫光
      expect(LyricPreferences.instance.fillMode, LyricFillMode.sweep);

      // 控件位于 ListView 末尾，测试视口（800×600）折线以下不构建，先滚进来。
      // 切换器本身是横向 Scrollable，必须显式指定纵向列表，否则 drag 目标歧义。
      await tester.scrollUntilVisible(
        find.text('字内渐变样式'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(find.text('字内渐变样式'));
      await tester.pumpAndSettle();
      expect(find.text('字内渐变样式'), findsOneWidget);

      // M3EToggleButtonGroup 会在 Stack 上层叠加一份全透明的测量副本，
      // find.text 会命中两份；取 first 才是真实可点击的按钮。
      await tester.tap(find.text('经典').first);
      await tester.pumpAndSettle();
      expect(LyricPreferences.instance.fillMode, LyricFillMode.classic);
      // 落盘 key 与偏好一致（切换后重启仍生效）
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('lyric_fill_mode'), 'classic');

      await tester.tap(find.text('扫光').first);
      await tester.pumpAndSettle();
      expect(LyricPreferences.instance.fillMode, LyricFillMode.sweep);
    });

    testWidgets('动态颜色混色比例：仅「歌词动态颜色」开启时出现在本页', (tester) async {
      final prefs = LyricPreferences.instance;
      await prefs.setUseDynamicLyricColor(false);
      await pumpPage(tester);
      expect(find.text('动态颜色混色比例'), findsNothing,
          reason: '动态颜色关闭时比例无意义，不应显示');

      await prefs.setUseDynamicLyricColor(true);
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('动态颜色混色比例'), 300);
      expect(find.text('动态颜色混色比例'), findsOneWidget);
      // 默认比例 = 历史观感 15%
      expect(prefs.dynamicColorMixRatio, equals(0.15));
    });

    testWidgets('辉光强度：仅「歌词辉光效果」开启时出现在本页', (tester) async {
      final prefs = LyricPreferences.instance;
      await prefs.setUseGlowEffect(false);
      await pumpPage(tester);
      expect(find.text('辉光强度'), findsNothing,
          reason: '辉光关闭时强度无意义，不应显示');

      await prefs.setUseGlowEffect(true);
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('辉光强度'), 300);
      expect(find.text('辉光强度'), findsOneWidget);
      // 默认强度 = 历史观感 100%
      expect(prefs.glowIntensity, equals(1.0));
      expect(find.text('100%'), findsOneWidget);
    });

    testWidgets('辉光强度：标签按百分比显示偏好值', (tester) async {
      final prefs = LyricPreferences.instance;
      await prefs.setUseGlowEffect(true);
      await pumpPage(tester);
      await tester.scrollUntilVisible(find.text('辉光强度'), 300);
      expect(find.text('100%'), findsOneWidget);

      await prefs.setGlowIntensity(1.75);
      await tester.pumpAndSettle();
      expect(find.text('175%'), findsOneWidget);
      // 落盘 key 与偏好一致（重启后仍生效）
      final storage = await SharedPreferences.getInstance();
      expect(storage.getDouble('lyric_glow_intensity'), equals(1.75));
    });

    testWidgets('重置确认弹窗覆盖字内渐变样式（回归本页第 10 项）', (tester) async {
      await pumpPage(tester);
      final prefs = LyricPreferences.instance;
      await prefs.setFillMode(LyricFillMode.classic);
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.restart_alt));
      await tester.pumpAndSettle();
      // 弹窗正文已列出新项
      expect(
        find.textContaining('字内渐变样式'),
        findsWidgets,
      );
      expect(
        find.textContaining('动态颜色混色比例'),
        findsWidgets,
      );
      // 新增的辉光强度也必须在重置确认弹窗里列出
      expect(
        find.textContaining('辉光强度'),
        findsWidgets,
      );

      await tester.tap(find.text('恢复默认'));
      await tester.pumpAndSettle();
      expect(prefs.fillMode, equals(LyricFillMode.sweep));
    });
  });
}
