import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'mcp_http_server.dart';
import 'mcp_jsonrpc.dart';
import 'mcp_library_source.dart';
import 'mcp_ports.dart';
import 'mcp_settings.dart';
import 'mcp_tool.dart';
import 'mcp_tools_library.dart';

enum McpStatus { stopped, starting, running, error }

/// 单次工具调用日志（设置页展示最近 20 条，用于确认"到底连上没有"）。
class McpCallLogEntry {
  McpCallLogEntry(this.at, this.tool, this.ok);

  final DateTime at;
  final String tool;
  final bool ok;
}

/// MCP 服务的总控：持有设置、传输层、分发器与工具注册表。
///
/// 构造后按持久化设置自动启动（默认关闭，即默认什么都不做：不 bind 端口、
/// 不读 token 以外的任何东西）。
class McpService extends ChangeNotifier {
  // 这里刻意不用初始化形参（`required this._playerControl`）：那会把公开命名
  // 参数改成 `_playerControl`，调用方将无法写 `playerControl:`。
  McpService({
    required McpPlayerControl playerControl,
    McpLibrarySource? library,
    McpSettingsStore? store,
    McpHttpServer? server,
    // ignore: prefer_initializing_formals
  })  : _playerControl = playerControl,
        _library = library ?? KugouApiClientLibrarySource(),
        _store = store ?? McpSettingsStore(),
        _server = server ?? McpHttpServer() {
    unawaited(_autoStart());
  }

  final McpPlayerControl _playerControl;
  final McpLibrarySource _library;
  final McpSettingsStore _store;
  final McpHttpServer _server;

  McpSettings? _settings;
  McpStatus _status = McpStatus.stopped;
  String? _error;
  String? _lanAddress;
  bool _disposed = false;
  final List<McpCallLogEntry> _log = <McpCallLogEntry>[];

  McpStatus get status => _status;
  String? get error => _error;
  McpSettings? get settings => _settings;
  int get port => _server.port;
  bool get isRunning => _status == McpStatus.running;
  List<McpCallLogEntry> get log => List<McpCallLogEntry>.unmodifiable(_log);

  /// 客户端可直接使用的 URL（LAN 模式下为实际网卡 IP）。
  ///
  /// 未监听时返回空串：默认（关闭）状态下不应该展示任何可配置的连接信息。
  ///
  /// LAN 模式的 IP 需要异步解析，解析完成前同样返回空串（解析完会
  /// notifyListeners，UI 随之刷新出完整 URL）。
  String get endpointUrl {
    final s = _settings;
    final port = _server.port;
    if (s == null || port == 0) return '';
    if (s.bindLan) {
      final lan = _lanAddress;
      if (lan == null) return '';
      return 'http://$lan:$port/mcp';
    }
    return 'http://127.0.0.1:$port/mcp';
  }

  Future<void> _autoStart() async {
    final settings = await _store.load();
    // provider 可能已在持久化读取完成前被销毁（热重载 / App 退出）：此时
    // 不能再 notify，更不能去 bind 一个没人负责关闭的端口。
    if (_disposed) return;
    _settings = settings;
    // 设置页 `watch` 本服务：装载完成必须通知一次，否则 UI 会在异步读取
    // 完成前一直显示未加载态（SettingsRepository 读取需要一帧以上）。
    notifyListeners();
    if (!settings.enabled) return;
    await start();
  }

  Future<void> start() async {
    if (_status == McpStatus.running || _status == McpStatus.starting) return;
    final settings = _settings ?? await _store.load();
    _settings = settings;
    _status = McpStatus.starting;
    _error = null;
    notifyListeners();
    try {
      final registry = McpToolRegistry(
        buildMcpTools(control: _playerControl, library: _library),
        onCall: recordCall,
      );
      registry.readOnly = settings.readOnly;
      final dispatcher = McpDispatcher(
        serverName: 'MD3Music',
        serverVersion: '5.7.0',
        tools: registry,
        instructions: 'MD3Music 播放器控制接口。先调用 md3_search_songs 获取 hash，'
            '再用 md3_play_song 播放；读状态用 md3_get_player_state。',
      );
      await _server.start(
        dispatcher: dispatcher,
        preferredPort: settings.port,
        bindLan: settings.bindLan,
        token: settings.token,
        requireAuth: settings.bindLan,
      );
      _status = McpStatus.running;
      // LAN 模式才需要网卡 IP；回环模式用固定 127.0.0.1，不必解析。
      if (settings.bindLan) unawaited(_resolveLanAddress());
    } catch (e) {
      _status = McpStatus.error;
      _error = '$e';
    }
    notifyListeners();
  }

  Future<void> stop() async {
    await _server.stop();
    _status = McpStatus.stopped;
    notifyListeners();
  }

  Future<void> update(McpSettings next) async {
    await _store.save(next);
    _settings = next;
    await stop();
    if (next.enabled) {
      await start();
    }
    notifyListeners();
  }

  Future<String> regenerateToken() async {
    final token = await _store.regenerateToken();
    await update((_settings ?? await _store.load()).copyWith(token: token));
    return token;
  }

  /// 由传输层在每次 tools/call 完成后回调，用于设置页的"最近调用"。
  void recordCall(String tool, bool ok) {
    if (_log.length >= 20) _log.removeRange(19, _log.length);
    _log.insert(0, McpCallLogEntry(DateTime.now(), tool, ok));
    notifyListeners();
  }

  /// 解析本机局域网 IPv4（供 [endpointUrl] 展示）。
  ///
  /// 判定口径与 DLNA 本地 HTTP 服务一致（见
  /// `core/services/local_http_server.dart`）：跳过蜂窝/VPN 接口，优先取
  /// wlan/eth，避免给用户一个手机上根本连不通的 CGNAT 地址。
  Future<void> _resolveLanAddress() async {
    String? resolved;
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
        includeLinkLocal: false,
      );
      String? fallback;
      for (final iface in interfaces) {
        final name = iface.name.toLowerCase();
        final isMobileOrVpn = name.startsWith('rmnet') ||
            name.startsWith('pdp') ||
            name.startsWith('tun') ||
            name.startsWith('ppp');
        if (isMobileOrVpn) continue;
        for (final addr in iface.addresses) {
          if (addr.isLoopback || addr.isLinkLocal) continue;
          fallback ??= addr.address;
          final isWiredOrWifi = name.startsWith('wlan') ||
              name.startsWith('eth') ||
              name.startsWith('wifi') ||
              name.startsWith('ap');
          if (isWiredOrWifi) {
            resolved = addr.address;
            break;
          }
        }
        if (resolved != null) break;
      }
      resolved ??= fallback;
    } catch (_) {
      // 无权限/无网卡：保持 null，UI 侧展示为"未连接"，不影响服务本身
    }
    if (resolved == _lanAddress) return;
    _lanAddress = resolved;
    notifyListeners();
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    await _server.stop();
    super.dispose();
  }
}
