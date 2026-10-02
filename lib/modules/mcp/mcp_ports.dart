import 'package:md3music/data/models/song.dart';
import 'package:md3music/services/kugou_api/kugou_models.dart';

/// 循环模式占位名，对齐 `AppLoopMode.off.name`（见 providers/player_provider.dart）。
///
/// 这里刻意不导入 provider：本文件被工具层与测试共同引用，引入 provider 会把
/// audio_service / just_audio 的整条依赖链拖进纯逻辑层。
const String kDefaultLoopModeName = 'off';

/// 播放器状态快照（工具层唯一允许读取的播放器视图）。
///
/// 只暴露 AI 需要的字段，避免把 Song 的全部内部字段倒进上下文。
class McpPlayerSnapshot {
  const McpPlayerSnapshot({
    required this.song,
    required this.playing,
    required this.positionMs,
    required this.durationMs,
    required this.volume,
    required this.loopMode,
    required this.shuffle,
    required this.queueLength,
    required this.currentIndex,
  });

  factory McpPlayerSnapshot.empty() => McpPlayerSnapshot(
        song: null,
        playing: false,
        positionMs: 0,
        durationMs: 0,
        volume: 1.0,
        loopMode: kDefaultLoopModeName,
        shuffle: false,
        queueLength: 0,
        currentIndex: -1,
      );

  final Song? song;
  final bool playing;
  final int positionMs;
  final int durationMs;
  final double volume;
  final String loopMode;
  final bool shuffle;
  final int queueLength;
  final int currentIndex;

  Map<String, Object?> toJson() => <String, Object?>{
        'title': song?.title,
        'artist': song?.artist,
        'album': song?.album,
        'playing': playing,
        'position_ms': positionMs,
        'duration_ms': durationMs,
        // 平台音量的浮点噪声（如 0.30000000000000004）没必要进模型上下文
        'volume': double.parse(volume.toStringAsFixed(2)),
        'loop_mode': loopMode,
        'shuffle': shuffle,
        'queue_length': queueLength,
        'current_index': currentIndex,
      };
}

/// 播放器控制端口。真实实现包装 PlayerProvider，测试用 FakePlayerControl。
abstract interface class McpPlayerControl {
  McpPlayerSnapshot snapshot();

  Future<void> resume();
  Future<void> pause();
  Future<void> next();
  Future<void> previous();
  Future<void> seek(Duration position);
  Future<void> setVolume(double volume);

  /// 队列投影（每项含 index/title/artist/album），从当前曲目起最多 [limit] 条。
  List<Map<String, Object?>> queue({int limit = 20});

  /// 立即播放（真实实现里在线曲目走 playOnlineSong，本地曲目走 playSong）。
  Future<void> playSong(Song song);

  /// 插入到当前曲目之后。
  Future<void> enqueue(Song song);
}

/// 曲库检索端口。真实实现包装 KugouApiClient。
abstract interface class McpLibrarySource {
  Future<List<KugouSongDetail>> searchSongs(String keyword, {int limit = 10});

  /// 按 hash 取歌曲详情，用于 `md3_play_song` / `md3_enqueue_song`。
  Future<KugouSongDetail?> getSongDetail(String hash);

  /// 返回 LRC 明文；无歌词时返回 null。
  Future<String?> getLyric(String hash);
}
