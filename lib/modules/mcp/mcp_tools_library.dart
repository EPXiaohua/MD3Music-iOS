import 'dart:async';

import 'package:md3music/modules/mcp/mcp_ports.dart';
import 'package:md3music/modules/mcp/mcp_tool.dart';
import 'package:md3music/modules/mcp/mcp_tools_player.dart';
import 'package:md3music/services/kugou_api/kugou_models.dart';

/// 歌词返回上限：超出部分截断，避免单条工具结果吃掉整轮上下文。
const int kMcpLyricMaxChars = 8000;

/// 歌曲结果投影：酷狗原始响应字段极多，只保留 AI 决策需要的 5 个。
///
/// 走 `toSong()` 而非直接读字面字段，保证这里给出的 name 与
/// `md3_play_song` / `md3_play_keyword` 回执的曲名一致（`toSong` 会剥掉
/// "歌手 - 歌名" 形式的前缀）。
Map<String, Object?> _projectSong(KugouSongDetail s) {
  final song = s.toSong();
  return <String, Object?>{
    'hash': s.hash,
    'name': song.title,
    'artist': song.artist,
    'album': song.album,
    // KugouSongDetail.duration 单位是秒
    'duration_ms': song.duration.inMilliseconds,
  };
}

/// 检索 / 歌词 / 按标识播放类工具（依赖 [McpLibrarySource] + [McpPlayerControl]）。
List<McpTool> buildLibraryTools({
  required McpLibrarySource library,
  required McpPlayerControl control,
}) =>
    <McpTool>[
      McpTool(
        name: 'md3_search_songs',
        description: '按关键词搜索歌曲，返回匹配歌曲的 hash、歌名、歌手、专辑与时长（毫秒）。'
            'hash 可用于 md3_play_song / md3_enqueue_song / md3_get_lyric。',
        inputSchema: <String, Object?>{
          'type': 'object',
          'properties': <String, Object?>{
            'keyword': <String, Object?>{'type': 'string', 'description': '搜索关键词'},
            'limit': <String, Object?>{
              'type': 'integer',
              'description': '返回条数，1-30，默认 10',
            },
          },
          'required': <Object?>['keyword'],
        },
        handler: (args) async {
          final keyword = requireString(args, 'keyword');
          final limit = optionalInt(args, 'limit', fallback: 10, min: 1, max: 30);
          final songs = await library.searchSongs(keyword, limit: limit);
          return McpToolResult(<String, Object?>{
            'keyword': keyword,
            'count': songs.length,
            'items': songs.map(_projectSong).toList(growable: false),
          });
        },
      ),
      McpTool(
        name: 'md3_get_lyric',
        description: '按歌曲 hash 取 LRC 歌词明文（带时间轴），最长 8000 字符。',
        inputSchema: <String, Object?>{
          'type': 'object',
          'properties': <String, Object?>{
            'hash': <String, Object?>{'type': 'string', 'description': '歌曲 hash'},
          },
          'required': <Object?>['hash'],
        },
        handler: (args) async {
          final hash = requireString(args, 'hash');
          final lyric = await library.getLyric(hash);
          if (lyric == null) return const McpToolResult.error('未找到该歌曲的歌词');
          final text = lyric.length > kMcpLyricMaxChars
              ? lyric.substring(0, kMcpLyricMaxChars)
              : lyric;
          return McpToolResult(<String, Object?>{
            'hash': hash,
            'truncated': text.length < lyric.length,
            'lyric': text,
          });
        },
      ),
      McpTool(
        name: 'md3_play_song',
        description: '按歌曲 hash 立即播放该歌曲（在线曲目会先解析播放链接）。',
        inputSchema: <String, Object?>{
          'type': 'object',
          'properties': <String, Object?>{
            'hash': <String, Object?>{'type': 'string', 'description': '歌曲 hash'},
          },
          'required': <Object?>['hash'],
        },
        isMutating: true,
        handler: (args) async {
          final hash = requireString(args, 'hash');
          final detail = await library.getSongDetail(hash);
          if (detail == null) return McpToolResult.error('未找到 hash 为 $hash 的歌曲');
          final song = detail.toSong();
          // 播放是长链路（URL 解析 + flac 加载，实测可达 60s+）。若在工具调用里
          // await 到播放就绪，MCP 客户端会先超时并**重试同一调用**，导致正在播的
          // 歌被切回开头（实测复现）。因此这里只触发、立即返回，成败由
          // md3_get_player_state 查询。
          unawaited(control.playSong(song));
          return McpToolResult(<String, Object?>{
            'playing': true,
            'title': song.title,
            'artist': song.artist,
          });
        },
      ),
      McpTool(
        name: 'md3_play_keyword',
        description: '搜索关键词并立即播放最匹配的第一首歌。等价于先 md3_search_songs 再 md3_play_song。',
        inputSchema: <String, Object?>{
          'type': 'object',
          'properties': <String, Object?>{
            'keyword': <String, Object?>{'type': 'string', 'description': '搜索关键词'},
          },
          'required': <Object?>['keyword'],
        },
        isMutating: true,
        handler: (args) async {
          final keyword = requireString(args, 'keyword');
          final songs = await library.searchSongs(keyword, limit: 1);
          if (songs.isEmpty) return McpToolResult.error('没有搜索到与「$keyword」匹配的歌曲');
          final song = songs.first.toSong();
          // 播放是长链路（URL 解析 + flac 加载，实测可达 60s+）。若在工具调用里
          // await 到播放就绪，MCP 客户端会先超时并**重试同一调用**，导致正在播的
          // 歌被切回开头（实测复现）。因此这里只触发、立即返回，成败由
          // md3_get_player_state 查询。
          unawaited(control.playSong(song));
          return McpToolResult(<String, Object?>{
            'playing': true,
            'title': song.title,
            'artist': song.artist,
            'hash': songs.first.hash,
          });
        },
      ),
      McpTool(
        name: 'md3_enqueue_song',
        description: '按歌曲 hash 把歌曲插入到当前曲目之后（不打断正在播放的歌）。',
        inputSchema: <String, Object?>{
          'type': 'object',
          'properties': <String, Object?>{
            'hash': <String, Object?>{'type': 'string', 'description': '歌曲 hash'},
          },
          'required': <Object?>['hash'],
        },
        isMutating: true,
        handler: (args) async {
          final hash = requireString(args, 'hash');
          final detail = await library.getSongDetail(hash);
          if (detail == null) return McpToolResult.error('未找到 hash 为 $hash 的歌曲');
          final song = detail.toSong();
          await control.enqueue(song);
          return McpToolResult(<String, Object?>{
            'enqueued': true,
            'title': song.title,
            'artist': song.artist,
          });
        },
      ),
    ];

/// 全部工具的装配入口（播放器工具 + 检索工具），供 `McpService` 注入注册表。
List<McpTool> buildMcpTools({
  required McpPlayerControl control,
  required McpLibrarySource library,
}) =>
    <McpTool>[
      ...buildPlayerTools(control),
      ...buildLibraryTools(library: library, control: control),
    ];
