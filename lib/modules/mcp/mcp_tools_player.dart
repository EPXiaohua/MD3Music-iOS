import 'package:md3music/modules/mcp/mcp_ports.dart';
import 'package:md3music/modules/mcp/mcp_tool.dart';

const Map<String, Object?> _emptySchema = <String, Object?>{
  'type': 'object',
  'properties': <String, Object?>{},
};

/// 播放器状态与控制类工具（依赖 [McpPlayerControl]）。
List<McpTool> buildPlayerTools(McpPlayerControl control) => <McpTool>[
      McpTool(
        name: 'md3_get_player_state',
        description: '读取当前播放状态：曲目名/歌手/专辑、是否播放、播放进度（毫秒）、'
            '总时长、音量、循环模式、随机播放、队列长度与当前索引。无曲目时曲目字段为空。'
            'loop_mode 取值：off（不循环）/ one（单曲循环）/ all（列表循环）。',
        inputSchema: _emptySchema,
        handler: (_) async => McpToolResult(control.snapshot().toJson()),
      ),
      McpTool(
        name: 'md3_get_queue',
        description: '读取当前播放队列（从当前曲目开始，最多 50 条）与当前所在索引。',
        inputSchema: <String, Object?>{
          'type': 'object',
          'properties': <String, Object?>{
            'limit': <String, Object?>{
              'type': 'integer',
              'description': '返回条数，1-50，默认 20',
            },
          },
        },
        handler: (args) async {
          final limit = optionalInt(args, 'limit', fallback: 20, min: 1, max: 50);
          final snapshot = control.snapshot();
          return McpToolResult(<String, Object?>{
            'current_index': snapshot.currentIndex,
            'total': snapshot.queueLength,
            'items': control.queue(limit: limit),
          });
        },
      ),
      McpTool(
        name: 'md3_resume',
        description: '继续播放当前曲目。若当前没有任何曲目则返回错误。',
        inputSchema: _emptySchema,
        isMutating: true,
        handler: (_) async {
          if (control.snapshot().song == null) {
            return const McpToolResult.error('当前没有曲目，无法继续播放');
          }
          await control.resume();
          return const McpToolResult.text('已继续播放');
        },
      ),
      McpTool(
        name: 'md3_pause',
        description: '暂停当前播放。',
        inputSchema: _emptySchema,
        isMutating: true,
        handler: (_) async {
          await control.pause();
          return const McpToolResult.text('已暂停');
        },
      ),
      McpTool(
        name: 'md3_next',
        description: '切到下一首。',
        inputSchema: _emptySchema,
        isMutating: true,
        handler: (_) async {
          await control.next();
          return const McpToolResult.text('已切到下一首');
        },
      ),
      McpTool(
        name: 'md3_previous',
        description: '切到上一首。',
        inputSchema: _emptySchema,
        isMutating: true,
        handler: (_) async {
          await control.previous();
          return const McpToolResult.text('已切到上一首');
        },
      ),
      McpTool(
        name: 'md3_seek',
        description: '跳转到指定播放位置（绝对毫秒，从 0 开始）。',
        inputSchema: <String, Object?>{
          'type': 'object',
          'properties': <String, Object?>{
            'position_ms': <String, Object?>{
              'type': 'integer',
              'description': '目标位置，单位毫秒，>= 0',
            },
          },
          'required': <Object?>['position_ms'],
        },
        isMutating: true,
        handler: (args) async {
          final ms = requireInt(args, 'position_ms', min: 0);
          await control.seek(Duration(milliseconds: ms));
          return McpToolResult.text('已跳转到 ${ms}ms');
        },
      ),
      McpTool(
        name: 'md3_set_volume',
        description: '设置播放音量，取值 0.0（静音）到 1.0（最大）。',
        inputSchema: <String, Object?>{
          'type': 'object',
          'properties': <String, Object?>{
            'volume': <String, Object?>{
              'type': 'number',
              'description': '音量，0.0 - 1.0',
            },
          },
          'required': <Object?>['volume'],
        },
        isMutating: true,
        handler: (args) async {
          final v = requireDouble(args, 'volume', min: 0.0, max: 1.0);
          await control.setVolume(v);
          return McpToolResult.text('音量已设为 ${v.toStringAsFixed(2)}');
        },
      ),
    ];
