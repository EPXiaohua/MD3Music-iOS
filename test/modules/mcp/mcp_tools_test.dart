import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/data/models/song.dart';
import 'package:md3music/modules/mcp/mcp_library_source.dart';
import 'package:md3music/modules/mcp/mcp_ports.dart';
import 'package:md3music/modules/mcp/mcp_tool.dart';
import 'package:md3music/modules/mcp/mcp_tools_library.dart';
import 'package:md3music/modules/mcp/mcp_tools_player.dart';
import 'package:md3music/services/kugou_api/kugou_models.dart';

Song _song() => const Song(
      id: 'h1',
      title: '晴天',
      artist: '周杰伦',
      album: '叶惠美',
      duration: Duration(seconds: 269),
    );

McpPlayerSnapshot _playingSnapshot({double volume = 1.0}) =>
    McpPlayerSnapshot(
      song: _song(),
      playing: true,
      positionMs: 1000,
      durationMs: 269000,
      volume: volume,
      loopMode: 'all',
      shuffle: false,
      queueLength: 2,
      currentIndex: 0,
    );

/// [McpPlayerControl] 的假实现：记录调用序列，返回构造好的快照。
class FakePlayerControl implements McpPlayerControl {
  FakePlayerControl({
    McpPlayerSnapshot? snapshot,
    this.queueItems = const <Map<String, Object?>>[],
  }) : _snapshot = snapshot ?? McpPlayerSnapshot.empty();

  final McpPlayerSnapshot _snapshot;

  /// [queue] 的返回值，默认空队列。
  final List<Map<String, Object?>> queueItems;

  final List<String> calls = <String>[];

  @override
  McpPlayerSnapshot snapshot() => _snapshot;

  @override
  List<Map<String, Object?>> queue({int limit = 20}) =>
      queueItems.take(limit).toList(growable: false);

  @override
  Future<void> resume() async => calls.add('resume');

  @override
  Future<void> pause() async => calls.add('pause');

  @override
  Future<void> next() async => calls.add('next');

  @override
  Future<void> previous() async => calls.add('previous');

  @override
  Future<void> seek(Duration position) async =>
      calls.add('seek:${position.inMilliseconds}');

  @override
  Future<void> setVolume(double volume) async =>
      calls.add('volume:${volume.toStringAsFixed(2)}');

  @override
  Future<void> playSong(Song song) async => calls.add('play:${song.title}');

  @override
  Future<void> enqueue(Song song) async => calls.add('enqueue:${song.title}');
}

/// 假的上游网关：直接返回构造好的模型，不触网。
///
/// 同时实现 [McpLibrarySource]，后续 Task 6 可以直接把
/// `FakeApiClient()` 当 `library` 传给 `buildMcpTools`。
class FakeApiClient implements KugouLibraryGateway, McpLibrarySource {
  /// 上一次请求实际下发的 pagesize，用于验证 limit 的钳制。
  int? lastPagesize;

  /// 搜索响应比请求量多返回的条数，用于验证上层截断。
  static const int extraPagesize = 5;

  List<KugouSongDetail> _fakeSongs(String keyword, int count) =>
      List<KugouSongDetail>.generate(
        count,
        (i) => KugouSongDetail(
          hash: 'h$i',
          songName: '$keyword-$i',
          duration: 100 + i,
          // 搜索候选带封面（模拟 /search 行为），用于验证 getSongDetail
          // 的封面补齐：/audio 无封面时按 hash 命中候选回填
          artworkUri: 'https://img.example/$keyword/$i',
        ),
      );

  @override
  Future<KugouSearchResult?> search(
    String keyword, {
    required int pagesize,
  }) async {
    lastPagesize = pagesize;
    // 故意多返回几条，用于验证 searchSongs 的截断逻辑
    return KugouSearchResult(
      songs: _fakeSongs(keyword, pagesize + extraPagesize),
      total: pagesize + extraPagesize,
    );
  }

  @override
  Future<KugouSongDetail?> songDetail(String hash) async => KugouSongDetail(
        hash: hash,
        songName: '晴天',
        artistName: '周杰伦',
        albumName: '叶惠美',
        duration: 269,
        // /audio 无封面字段（铁律 17）：detail 永远不带图，靠搜索命中补齐
      );

  @override
  Future<KugouLyric?> lyric(String hash) async => KugouLyric(
        content: 'kVc9aU 加密占位内容',
        decodedContent: '[00:01.00] 故事的小黄花',
      );

  @override
  Future<List<KugouSongDetail>> searchSongs(
    String keyword, {
    int limit = 10,
  }) async =>
      _fakeSongs(keyword, limit);

  @override
  Future<KugouSongDetail?> getSongDetail(String hash) => songDetail(hash);

  @override
  Future<String?> getLyric(String hash) async =>
      (await lyric(hash))?.decodedContent;
}

/// 只覆盖"没有歌词"分支的最小网关：[lyricResult] 为 null 表示上游无歌词。
class StubGateway implements KugouLibraryGateway {
  StubGateway(this.lyricResult);

  final KugouLyric? lyricResult;

  @override
  Future<KugouSearchResult?> search(
    String keyword, {
    required int pagesize,
  }) async =>
      const KugouSearchResult();

  @override
  Future<KugouSongDetail?> songDetail(String hash) async => null;

  @override
  Future<KugouLyric?> lyric(String hash) async => lyricResult;
}

/// 什么都不返回的 [McpLibrarySource]：用于覆盖"详情缺失"分支。
class EmptyApiClient implements McpLibrarySource {
  @override
  Future<KugouSongDetail?> getSongDetail(String hash) async => null;

  @override
  Future<String?> getLyric(String hash) async => null;

  @override
  Future<List<KugouSongDetail>> searchSongs(
    String keyword, {
    int limit = 10,
  }) async =>
      const <KugouSongDetail>[];
}

/// 只返回超长歌词的 [McpLibrarySource]：用于验证歌词截断。
class LongLyricApiClient implements McpLibrarySource {
  @override
  Future<KugouSongDetail?> getSongDetail(String hash) async => null;

  @override
  Future<String?> getLyric(String hash) async => '词' * 20000;

  @override
  Future<List<KugouSongDetail>> searchSongs(
    String keyword, {
    int limit = 10,
  }) async =>
      const <KugouSongDetail>[];
}

void main() {
  group('播放器快照', () {
    test('空快照投影出全空曲目字段', () {
      final json = McpPlayerSnapshot.empty().toJson();
      expect(json['title'], isNull);
      expect(json['artist'], isNull);
      expect(json['album'], isNull);
      expect(json['playing'], isFalse);
      expect(json['position_ms'], 0);
      expect(json['duration_ms'], 0);
      expect(json['queue_length'], 0);
      expect(json['current_index'], -1);
    });

    test('带曲目快照投影出曲目信息与毫秒进度', () {
      final json = _playingSnapshot().toJson();
      expect(json['title'], '晴天');
      expect(json['artist'], '周杰伦');
      expect(json['album'], '叶惠美');
      expect(json['playing'], isTrue);
      expect(json['position_ms'], 1000);
      expect(json['duration_ms'], 269000);
      expect(json['loop_mode'], 'all');
      expect(json['shuffle'], isFalse);
      expect(json['queue_length'], 2);
      expect(json['current_index'], 0);
    });

    test('音量压缩到两位小数', () {
      expect(
        _playingSnapshot(volume: 0.567).toJson()['volume'],
        0.57,
      );
      expect(_playingSnapshot(volume: 1.0).toJson()['volume'], 1.0);
    });

    test('FakePlayerControl 按顺序记录调用', () async {
      final control = FakePlayerControl();
      await control.resume();
      await control.pause();
      await control.next();
      await control.previous();
      await control.seek(const Duration(seconds: 30));
      await control.setVolume(0.5);
      await control.playSong(_song());
      await control.enqueue(_song());
      expect(control.calls, <String>[
        'resume',
        'pause',
        'next',
        'previous',
        'seek:30000',
        'volume:0.50',
        'play:晴天',
        'enqueue:晴天',
      ]);
    });
  });

  group('曲库源', () {
    test('KugouApiClientLibrarySource.searchSongs 截断到 limit', () async {
      final fake = FakeApiClient();
      final source = KugouApiClientLibrarySource(fake);
      final songs = await source.searchSongs('周杰伦', limit: 3);
      expect(songs, hasLength(3));
      expect(songs.first.hash, 'h0');
      expect(fake.lastPagesize, 3);
    });

    test('KugouApiClientLibrarySource.searchSongs limit 上钳到 30', () async {
      final fake = FakeApiClient();
      final source = KugouApiClientLibrarySource(fake);
      final songs = await source.searchSongs('周杰伦', limit: 100);
      expect(songs, hasLength(30));
      expect(fake.lastPagesize, 30);
    });

    test('KugouApiClientLibrarySource.getSongDetail 透传 hash', () async {
      final source = KugouApiClientLibrarySource(FakeApiClient());
      final detail = await source.getSongDetail('abc');
      expect(detail, isNotNull);
      expect(detail!.hash, 'abc');
      expect(detail.songName, '晴天');
    });

    test('getSongDetail 封面补齐：/audio 无图时按 hash 命中搜索候选', () async {
      final source = KugouApiClientLibrarySource(FakeApiClient());
      // 'h0' 同时存在于搜索候选（_fakeSongs 生成 h0..hN，候选带封面）
      final detail = await source.getSongDetail('h0');
      expect(detail, isNotNull);
      expect(detail!.hash, 'h0');
      expect(detail.artworkUri, 'https://img.example/晴天 周杰伦/0');
    });

    test('getSongDetail 封面补齐：候选未命中时原样返回（无封面不抛）', () async {
      final source = KugouApiClientLibrarySource(FakeApiClient());
      // 'abc' 不在搜索候选里 → 不命中 → 返回 /audio 原始 detail
      final detail = await source.getSongDetail('abc');
      expect(detail, isNotNull);
      expect(detail!.hash, 'abc');
      expect(detail.artworkUri, isNull);
    });

    test('KugouApiClientLibrarySource.getLyric 优先解码内容', () async {
      final source = KugouApiClientLibrarySource(FakeApiClient());
      expect(await source.getLyric('h1'), contains('[00:01.00]'));
    });

    test('KugouApiClientLibrarySource.getLyric 上游无歌词时返回 null', () async {
      final source = KugouApiClientLibrarySource(StubGateway(null));
      expect(await source.getLyric('h1'), isNull);
    });

    test('KugouApiClientLibrarySource.getLyric 空白歌词返回 null', () async {
      final source = KugouApiClientLibrarySource(
        StubGateway(const KugouLyric(content: '   ', decodedContent: '  ')),
      );
      expect(await source.getLyric('h1'), isNull);
    });
  });

  group('播放器工具', () {
    test('md3_get_player_state 返回投影快照', () async {
      final control = FakePlayerControl(snapshot: _playingSnapshot(volume: 0.5));
      final registry = McpToolRegistry(buildPlayerTools(control));
      final res = await registry.execute('md3_get_player_state', <String, Object?>{});
      expect(res.isError, isFalse);
      final data = res.data! as Map<String, Object?>;
      expect(data['title'], '晴天');
      expect(data['artist'], '周杰伦');
      expect(data['position_ms'], 1000);
      expect(data['duration_ms'], 269000);
      expect(data['volume'], 0.5);
      expect(data['loop_mode'], 'all');
      expect(data['queue_length'], 2);
    });

    test('md3_get_player_state 无曲目时曲目字段为空', () async {
      final registry = McpToolRegistry(buildPlayerTools(FakePlayerControl()));
      final res = await registry.execute('md3_get_player_state', <String, Object?>{});
      final data = res.data! as Map<String, Object?>;
      expect(data['title'], isNull);
      expect(data['playing'], isFalse);
      expect(data['current_index'], -1);
    });

    test('md3_get_queue 返回队列条目与当前索引', () async {
      final control = FakePlayerControl(
        snapshot: _playingSnapshot(),
        queueItems: <Map<String, Object?>>[
          <String, Object?>{'index': 0, 'title': '晴天', 'artist': '周杰伦', 'album': '叶惠美'},
          <String, Object?>{'index': 1, 'title': '稻香', 'artist': '周杰伦', 'album': '魔杰座'},
        ],
      );
      final registry = McpToolRegistry(buildPlayerTools(control));
      final res = await registry.execute('md3_get_queue', <String, Object?>{});
      final data = res.data! as Map<String, Object?>;
      expect(data['current_index'], 0);
      expect(data['total'], 2);
      expect(data['items'], hasLength(2));
      expect((data['items']! as List).first as Map, containsPair('title', '晴天'));
    });

    test('md3_get_queue 拒绝越界 limit', () async {
      final registry = McpToolRegistry(buildPlayerTools(FakePlayerControl()));
      expect(
        (await registry.execute(
          'md3_get_queue',
          <String, Object?>{'limit': 51},
        )).isError,
        isTrue,
      );
    });

    test('md3_resume 在无曲目时返回错误而不调用控制层', () async {
      final control = FakePlayerControl();
      final registry = McpToolRegistry(buildPlayerTools(control));
      final res = await registry.execute('md3_resume', <String, Object?>{});
      expect(res.isError, isTrue);
      expect(control.calls, isEmpty);
    });

    test('md3_resume 有曲目时调用控制层', () async {
      final control = FakePlayerControl(snapshot: _playingSnapshot());
      final registry = McpToolRegistry(buildPlayerTools(control));
      final res = await registry.execute('md3_resume', <String, Object?>{});
      expect(res.isError, isFalse);
      expect(control.calls, ['resume']);
    });

    test('md3_pause 调用控制层并回执文本', () async {
      final control = FakePlayerControl();
      final registry = McpToolRegistry(buildPlayerTools(control));
      final res = await registry.execute('md3_pause', <String, Object?>{});
      expect(res.isError, isFalse);
      expect(res.text, '已暂停');
      expect(control.calls, ['pause']);
    });

    test('md3_next / md3_previous 转发到控制层', () async {
      final control = FakePlayerControl();
      final registry = McpToolRegistry(buildPlayerTools(control));
      await registry.execute('md3_next', <String, Object?>{});
      await registry.execute('md3_previous', <String, Object?>{});
      expect(control.calls, ['next', 'previous']);
    });

    test('md3_seek 到达控制层时以毫秒为单位', () async {
      final control = FakePlayerControl();
      final registry = McpToolRegistry(buildPlayerTools(control));
      final res = await registry.execute(
        'md3_seek',
        <String, Object?>{'position_ms': 30000},
      );
      expect(res.isError, isFalse);
      expect(control.calls, ['seek:30000']);
    });

    test('md3_seek 拒绝负数', () async {
      final control = FakePlayerControl();
      final registry = McpToolRegistry(buildPlayerTools(control));
      final res = await registry.execute(
        'md3_seek',
        <String, Object?>{'position_ms': -1},
      );
      expect(res.isError, isTrue);
      expect(res.text, contains('参数错误'));
      expect(control.calls, isEmpty);
    });

    test('md3_seek 拒绝非整数', () async {
      final control = FakePlayerControl();
      final registry = McpToolRegistry(buildPlayerTools(control));
      expect(
        (await registry.execute(
          'md3_seek',
          <String, Object?>{'position_ms': 'abc'},
        )).isError,
        isTrue,
      );
      expect(control.calls, isEmpty);
    });

    test('md3_set_volume 在合法区间内调用控制层', () async {
      final control = FakePlayerControl();
      final registry = McpToolRegistry(buildPlayerTools(control));
      final res = await registry.execute(
        'md3_set_volume',
        <String, Object?>{'volume': 0.25},
      );
      expect(res.isError, isFalse);
      expect(control.calls, ['volume:0.25']);
    });

    test('md3_set_volume 拒绝越界值', () async {
      final control = FakePlayerControl();
      final registry = McpToolRegistry(buildPlayerTools(control));
      expect(
        (await registry.execute(
          'md3_set_volume',
          <String, Object?>{'volume': 1.5},
        )).isError,
        isTrue,
      );
      expect(control.calls, isEmpty);
    });

    test('只读模式下写工具被拦截而读工具仍可用', () async {
      final control = FakePlayerControl(snapshot: _playingSnapshot());
      final registry = McpToolRegistry(buildPlayerTools(control));
      registry.readOnly = true;
      final names = registry
          .visibleTools()
          .map((t) => t.name)
          .toList(growable: false);
      expect(names, ['md3_get_player_state', 'md3_get_queue']);
      final res = await registry.execute('md3_pause', <String, Object?>{});
      expect(res.isError, isTrue);
      expect(control.calls, isEmpty);
      expect(
        (await registry.execute('md3_get_player_state', <String, Object?>{})).isError,
        isFalse,
      );
    });
  });

  group('检索类工具', () {
    test('md3_search_songs 只投影 5 个字段', () async {
      final control = FakePlayerControl();
      final library = FakeApiClient();
      final registry = McpToolRegistry(
          buildMcpTools(control: control, library: library));
      final res = await registry.execute(
        'md3_search_songs',
        <String, Object?>{'keyword': '晴天'},
      );
      expect(res.isError, isFalse);
      final data = res.data! as Map<String, Object?>;
      expect(data['keyword'], '晴天');
      expect(data['count'], 10);
      final items = data['items']! as List;
      expect(items.first as Map, allOf(<Matcher>[
        containsPair('hash', 'h0'),
        containsPair('name', '晴天-0'),
      ]));
      expect(
        (items.first as Map).keys,
        unorderedEquals(<String>['hash', 'name', 'artist', 'album', 'duration_ms']),
      );
      // KugouSongDetail.duration 单位是秒，投影后必须是毫秒
      expect((items.first as Map)['duration_ms'], 100000);
    });

    test('md3_search_songs 拒绝空关键词', () async {
      final registry = McpToolRegistry(
          buildMcpTools(control: FakePlayerControl(), library: FakeApiClient()));
      expect(
        (await registry.execute(
          'md3_search_songs',
          <String, Object?>{'keyword': ''},
        )).isError,
        isTrue,
      );
    });

    test('md3_search_songs 拒绝越界 limit', () async {
      final registry = McpToolRegistry(
          buildMcpTools(control: FakePlayerControl(), library: FakeApiClient()));
      expect(
        (await registry.execute(
          'md3_search_songs',
          <String, Object?>{'keyword': '晴天', 'limit': 31},
        )).isError,
        isTrue,
      );
    });

    test('md3_get_lyric 超长截断到 8000 字符', () async {
      final registry = McpToolRegistry(
          buildMcpTools(control: FakePlayerControl(), library: LongLyricApiClient()));
      final res = await registry.execute('md3_get_lyric', <String, Object?>{'hash': 'x'});
      expect(res.isError, isFalse);
      final data = res.data! as Map<String, Object?>;
      expect((data['lyric']! as String).length, 8000);
      expect(data['truncated'], isTrue);
      expect(data['hash'], 'x');
    });

    test('md3_get_lyric 短歌词不截断', () async {
      final registry = McpToolRegistry(
          buildMcpTools(control: FakePlayerControl(), library: FakeApiClient()));
      final res = await registry.execute('md3_get_lyric', <String, Object?>{'hash': 'h1'});
      final data = res.data! as Map<String, Object?>;
      expect(data['lyric'], contains('[00:01.00]'));
      expect(data['truncated'], isFalse);
    });

    test('md3_get_lyric 无歌词时返回错误', () async {
      final registry = McpToolRegistry(
          buildMcpTools(control: FakePlayerControl(), library: EmptyApiClient()));
      final res = await registry.execute('md3_get_lyric', <String, Object?>{'hash': 'x'});
      expect(res.isError, isTrue);
      expect(res.text, contains('未找到'));
    });

    test('md3_play_keyword 播放首个搜索结果', () async {
      final control = FakePlayerControl();
      final registry = McpToolRegistry(
          buildMcpTools(control: control, library: FakeApiClient()));
      final res = await registry.execute(
        'md3_play_keyword',
        <String, Object?>{'keyword': '晴天'},
      );
      expect(res.isError, isFalse);
      expect(control.calls, ['play:晴天-0']);
      final data = res.data! as Map<String, Object?>;
      expect(data['title'], '晴天-0');
      expect(data['hash'], 'h0');
    });

    test('md3_play_keyword 无结果时返回错误', () async {
      final control = FakePlayerControl();
      final registry = McpToolRegistry(
          buildMcpTools(control: control, library: EmptyApiClient()));
      final res = await registry.execute(
        'md3_play_keyword',
        <String, Object?>{'keyword': '不存在'},
      );
      expect(res.isError, isTrue);
      expect(control.calls, isEmpty);
    });

    test('md3_play_song 详情缺失时返回错误', () async {
      final control = FakePlayerControl();
      final registry = McpToolRegistry(
          buildMcpTools(control: control, library: EmptyApiClient()));
      final res = await registry.execute('md3_play_song', <String, Object?>{'hash': 'x'});
      expect(res.isError, isTrue);
      expect(control.calls, isEmpty);
    });

    test('md3_play_song 按 hash 取详情后立即播放', () async {
      final control = FakePlayerControl();
      final registry = McpToolRegistry(
          buildMcpTools(control: control, library: FakeApiClient()));
      final res = await registry.execute('md3_play_song', <String, Object?>{'hash': 'h9'});
      expect(res.isError, isFalse);
      expect(control.calls, ['play:晴天']);
      final data = res.data! as Map<String, Object?>;
      expect(data['playing'], isTrue);
      expect(data['title'], '晴天');
      expect(data['artist'], '周杰伦');
    });

    test('md3_enqueue_song 插入队列而不打断当前播放', () async {
      final control = FakePlayerControl();
      final registry = McpToolRegistry(
          buildMcpTools(control: control, library: FakeApiClient()));
      final res = await registry.execute(
        'md3_enqueue_song',
        <String, Object?>{'hash': 'h2'},
      );
      expect(res.isError, isFalse);
      expect(control.calls, ['enqueue:晴天']);
      final data = res.data! as Map<String, Object?>;
      expect(data['enqueued'], isTrue);
      expect(data['title'], '晴天');
    });

    test('md3_enqueue_song 详情缺失时返回错误', () async {
      final control = FakePlayerControl();
      final registry = McpToolRegistry(
          buildMcpTools(control: control, library: EmptyApiClient()));
      final res = await registry.execute(
        'md3_enqueue_song',
        <String, Object?>{'hash': 'x'},
      );
      expect(res.isError, isTrue);
      expect(control.calls, isEmpty);
    });

    test('buildMcpTools 装配 13 个工具且只读模式隐藏写工具', () async {
      final registry = McpToolRegistry(buildMcpTools(
        control: FakePlayerControl(),
        library: FakeApiClient(),
      ));
      final names = registry.visibleTools().map((t) => t.name).toList(growable: false);
      expect(names, hasLength(13));
      expect(names, contains('md3_get_player_state'));
      expect(names, contains('md3_search_songs'));

      registry.readOnly = true;
      final readOnlyNames =
          registry.visibleTools().map((t) => t.name).toList(growable: false);
      expect(readOnlyNames, hasLength(4));
      expect(readOnlyNames, isNot(contains('md3_play_keyword')));
    });
  });
}
