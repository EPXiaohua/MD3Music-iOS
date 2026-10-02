import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart' as services;
import 'package:just_audio/just_audio.dart' as just_audio;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:md3music/data/models/song.dart';
import 'package:md3music/data/repositories/history_repository.dart';
import 'package:md3music/providers/player_provider.dart';
import 'package:md3music/widgets/player_artwork_image.dart';
import 'package:md3music/widgets/player_playlist_view.dart';
import '../support/controlled_audio_service.dart';

/// 队列面板的编辑 / 删除 / 排序：与歌单详情页同一套模型。
void main() {
  Song song(String id, String title, {int seconds = 60}) => Song(
    id: id,
    title: title,
    artist: 'artist',
    album: 'album',
    duration: Duration(seconds: seconds),
  );

  Widget host(PlayerProvider player) {
    return ChangeNotifierProvider<PlayerProvider>.value(
      value: player,
      child: MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 640,
            child: PlayerPlaylistView(useAmColors: false),
          ),
        ),
      ),
    );
  }

  void mockConnectivityStream() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(
          const services.EventChannel(
            'dev.fluttercommunity.plus/connectivity_status',
          ),
          MockStreamHandler.inline(
            onListen: (_, events) => events.success(<String>['wifi']),
          ),
        );
  }

  Future<(PlayerProvider, _ImmediateAudioService)> createPlayer(
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    mockConnectivityStream();
    final audio = _ImmediateAudioService();
    AudioServiceLoader.setTestOverride(() async => audio);
    late final PlayerProvider player;
    await tester.runAsync(() async {
      player = PlayerProvider();
      await player.audioReady.timeout(const Duration(seconds: 10));
    });
    return (player, audio);
  }

  Future<void> disposePlayer(
    WidgetTester tester,
    PlayerProvider player,
    _ImmediateAudioService audio,
  ) async {
    player.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() => HistoryRepository().flush());
    await tester.runAsync(audio.dispose);
    AudioServiceLoader.setTestOverride(null);
  }

  testWidgets('长按进入编辑模式：出现已选计数 / 全选 / 删除', (tester) async {
    final (player, audio) = await createPlayer(tester);
    try {
      await player.playPlaylist([
        song('s0', 'C'),
        song('s1', 'A'),
        song('s2', 'B'),
      ], 0);
      await tester.pumpWidget(host(player));
      await tester.pumpAndSettle();

      // 常态：标题 + 排序 + 编辑，没有多选顶栏
      expect(find.text('播放列表'), findsOneWidget);
      expect(find.byIcon(Icons.swap_vert), findsOneWidget);
      expect(find.byIcon(Icons.edit_outlined), findsOneWidget);
      expect(find.textContaining('已选'), findsNothing);

      await tester.longPress(find.text('B'));
      await tester.pumpAndSettle();

      expect(find.text('已选 1 首'), findsOneWidget);
      expect(find.text('全选'), findsOneWidget);
      expect(find.text('删除'), findsOneWidget);
      // 编辑模式下出现拖拽把手，复选框与封面并排（封面不消失）
      expect(find.byIcon(Icons.drag_handle), findsNWidgets(3));
      expect(find.byType(PlayerArtworkImage), findsNWidgets(3));
    } finally {
      await disposePlayer(tester, player, audio);
    }
  });

  testWidgets('全选后再点取消全选', (tester) async {
    final (player, audio) = await createPlayer(tester);
    try {
      await player.playPlaylist([
        song('s0', 'C'),
        song('s1', 'A'),
        song('s2', 'B'),
      ], 0);
      await tester.pumpWidget(host(player));
      await tester.pumpAndSettle();

      await tester.longPress(find.text('B'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('全选'));
      await tester.pumpAndSettle();
      expect(find.text('已选 3 首'), findsOneWidget);

      await tester.tap(find.text('取消全选'));
      await tester.pumpAndSettle();
      expect(find.text('已选 0 首'), findsOneWidget);
    } finally {
      await disposePlayer(tester, player, audio);
    }
  });

  testWidgets('1000首队列只构建视口内歌曲行', (tester) async {
    final (player, audio) = await createPlayer(tester);
    try {
      final songs = List.generate(
        1000,
        (index) => song('scale_$index', 'Scale $index'),
      );
      await player.playPlaylist(songs, 0);
      await tester.pumpWidget(host(player));
      await tester.pumpAndSettle();

      expect(find.text('Scale 0'), findsOneWidget);
      expect(find.text('Scale 999'), findsNothing);
      expect(find.byType(ListTile).evaluate().length, lessThan(20));
    } finally {
      await disposePlayer(tester, player, audio);
    }
  });

  testWidgets('5000首队列只构建视口内歌曲行', (tester) async {
    final (player, audio) = await createPlayer(tester);
    try {
      final songs = List.generate(
        5000,
        (index) => song('large_scale_$index', 'Large scale $index'),
      );
      await player.playPlaylist(songs, 0);
      await tester.pumpWidget(host(player));
      await tester.pumpAndSettle();

      expect(find.text('Large scale 0'), findsOneWidget);
      expect(find.text('Large scale 4999'), findsNothing);
      expect(find.byType(ListTile).evaluate().length, lessThan(20));
    } finally {
      await disposePlayer(tester, player, audio);
    }
  });

  testWidgets('按标题排序会真实重排队列', (tester) async {
    final (player, audio) = await createPlayer(tester);
    try {
      await player.playPlaylist([
        song('s0', 'C'),
        song('s1', 'A'),
        song('s2', 'B'),
      ], 0);
      await tester.pumpWidget(host(player));
      await tester.pumpAndSettle();

      // 点排序触发器（图标即 M3ESortButton 的字段），面板在 Overlay 中就展开
      await tester.tap(find.byIcon(Icons.swap_vert));
      await tester.pumpAndSettle();
      // 面板条目与旧菜单逐字相同，且界面别处没有同名文字，直接按文本点
      await tester.ensureVisible(find.text('标题'));
      await tester.tap(find.text('标题'));
      await tester.pumpAndSettle();

      expect(player.playlist.map((s) => s.title).toList(), [
        'A',
        'B',
        'C',
      ], reason: '排序写回队列本身，下一首也按新顺序走');
      expect(player.currentSong?.title, 'C', reason: '当前播放的歌不中断，只是索引跟到新位置');
      expect(player.playlist[player.currentIndex].title, 'C');
    } finally {
      await disposePlayer(tester, player, audio);
    }
  });

  testWidgets('删除选中歌曲：二次确认后从队列移除并退出编辑模式', (tester) async {
    final (player, audio) = await createPlayer(tester);
    try {
      await player.playPlaylist([
        song('s0', 'C'),
        song('s1', 'A'),
        song('s2', 'B'),
      ], 0);
      await tester.pumpWidget(host(player));
      await tester.pumpAndSettle();

      // 选中非当前播放的 'B'
      await tester.longPress(find.text('B'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text('确定从播放列表中删除选中的 1 首歌曲吗？'), findsOneWidget);
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('删除'),
        ),
      );
      await tester.pumpAndSettle();

      expect(player.playlist.map((s) => s.title).toList(), ['C', 'A']);
      // 删除后退出编辑模式
      expect(find.textContaining('已选'), findsNothing);
      expect(find.text('播放列表'), findsOneWidget);
    } finally {
      await disposePlayer(tester, player, audio);
    }
  });
}

class _ImmediateAudioService extends ControlledAudioService {
  @override
  Future<void> setPlaylist(
    List<just_audio.UriAudioSource> sources, {
    int startIndex = 0,
    Duration? initialPosition,
  }) async {}
}
