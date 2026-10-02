import 'package:md3music/modules/mcp/mcp_ports.dart';
import 'package:md3music/services/kugou_api/kugou_api_client.dart';
import 'package:md3music/services/kugou_api/kugou_models.dart';

/// [KugouApiClient] 的最小子集，即本文件真正用到的三个方法。
///
/// 为什么需要这层接缝：`KugouApiClient` 是单例（私有构造 + factory），外部既
/// 不能继承也无法低成本实现其全部成员，没有接缝就无法在单元测试里验证截断 /
/// 歌词降级这类纯逻辑，只能联网跑集成测试。
abstract interface class KugouLibraryGateway {
  Future<KugouSearchResult?> search(String keyword, {required int pagesize});

  Future<KugouSongDetail?> songDetail(String hash);

  Future<KugouLyric?> lyric(String hash);
}

/// [McpLibrarySource] 的真实实现：全部走既有的 [KugouApiClient]
/// （即本地 Rust 服务器 → 酷狗上游），不新增任何网络通道。
class KugouApiClientLibrarySource implements McpLibrarySource {
  KugouApiClientLibrarySource([KugouLibraryGateway? gateway])
      : _gateway = gateway ?? _KugouApiClientGateway();

  final KugouLibraryGateway _gateway;

  @override
  Future<List<KugouSongDetail>> searchSongs(
    String keyword, {
    int limit = 10,
  }) async {
    final clamped = limit.clamp(1, 30);
    final result = await _gateway.search(keyword, pagesize: clamped);
    final songs = result?.songs ?? const <KugouSongDetail>[];
    return songs.take(clamped).toList(growable: false);
  }

  @override
  Future<KugouSongDetail?> getSongDetail(String hash) async {
    final detail = await _gateway.songDetail(hash);
    if (detail == null) return null;
    // /audio 完全不返回封面字段（项目铁律 17：实测 0 个 img/pic/cover 键），
    // 封面 100% 依赖 /search 命中同 hash 的候选（与一起听富化同构）。
    // 因此封面缺失时用「歌名 歌手」搜一次，按 hash 精确匹配候选回填；
    // 搜不到或网络异常就原样返回（不影响播放本体），不做重试风暴。
    if ((detail.artworkUri ?? '').isNotEmpty) return detail;
    final keyword = <String>[
      if (detail.songName.trim().isNotEmpty) detail.songName,
      if ((detail.artistName ?? '').trim().isNotEmpty) detail.artistName!,
    ].join(' ').trim();
    if (keyword.isEmpty) return detail;
    try {
      final result = await _gateway.search(keyword, pagesize: 30);
      for (final candidate in result?.songs ?? const <KugouSongDetail>[]) {
        if (candidate.hash.toLowerCase() == hash.toLowerCase() &&
            (candidate.artworkUri ?? '').isNotEmpty) {
          return detail.copyWith(artworkUri: candidate.artworkUri);
        }
      }
    } catch (_) {
      // 封面补齐失败不阻断播放
    }
    return detail;
  }

  @override
  Future<String?> getLyric(String hash) async {
    final lyric = await _gateway.lyric(hash);
    final text = lyric?.decodedContent ?? lyric?.content;
    if (text == null || text.trim().isEmpty) return null;
    return text;
  }
}

class _KugouApiClientGateway implements KugouLibraryGateway {
  KugouApiClient? _client;

  // 懒构造：单测注入假网关时不会碰真实客户端（它会启动 dio / 读本地存储）
  KugouApiClient get client => _client ??= KugouApiClient();

  @override
  Future<KugouSearchResult?> search(String keyword, {required int pagesize}) =>
      client.search(keyword, page: 1, pagesize: pagesize);

  @override
  Future<KugouSongDetail?> songDetail(String hash) => client.getSongDetail(hash);

  @override
  Future<KugouLyric?> lyric(String hash) => client.getLyric(hash);
}
