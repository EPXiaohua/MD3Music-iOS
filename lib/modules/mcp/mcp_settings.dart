import 'dart:convert';
import 'dart:math';

import 'package:md3music/data/repositories/settings_repository.dart';

/// MCP 服务配置快照。
class McpSettings {
  const McpSettings({
    required this.enabled,
    required this.port,
    required this.bindLan,
    required this.readOnly,
    required this.token,
  });

  final bool enabled;

  /// 监听端口（默认 17888）。端口固定是刚需：MCP 客户端配置是静态 URL。
  final int port;

  /// true = 绑定 0.0.0.0（局域网可达，强制 token 鉴权）；false = 仅回环。
  final bool bindLan;

  /// true = 隐藏并拒绝所有会改变播放状态的工具。
  final bool readOnly;

  final String token;

  McpSettings copyWith({
    bool? enabled,
    int? port,
    bool? bindLan,
    bool? readOnly,
    String? token,
  }) =>
      McpSettings(
        enabled: enabled ?? this.enabled,
        port: port ?? this.port,
        bindLan: bindLan ?? this.bindLan,
        readOnly: readOnly ?? this.readOnly,
        token: token ?? this.token,
      );
}

class McpSettingsStore {
  McpSettingsStore([SettingsRepository? repository])
      : _repo = repository ?? SettingsRepository();

  final SettingsRepository _repo;

  Future<McpSettings> load() async {
    final token = await _repo.getMcpToken();
    return McpSettings(
      enabled: await _repo.getMcpEnabled(),
      port: await _repo.getMcpPort(),
      bindLan: await _repo.getMcpBindLan(),
      readOnly: await _repo.getMcpReadOnly(),
      // 首次读取即生成并落盘，保证 token 在会话间稳定
      token: token.isEmpty ? await regenerateToken() : token,
    );
  }

  Future<void> save(McpSettings s) async {
    await _repo.setMcpEnabled(s.enabled);
    await _repo.setMcpPort(s.port);
    await _repo.setMcpBindLan(s.bindLan);
    await _repo.setMcpReadOnly(s.readOnly);
    await _repo.setMcpToken(s.token);
  }

  Future<String> regenerateToken() async {
    final bytes = List<int>.generate(32, (_) => Random.secure().nextInt(256));
    final token = base64UrlEncode(bytes).replaceAll('=', '');
    await _repo.setMcpToken(token);
    return token;
  }
}
