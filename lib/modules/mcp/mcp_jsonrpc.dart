import 'mcp_tool.dart';

/// JSON-RPC 2.0 标准错误码。MCP 在此基础上保留 -32000 段给业务错误，
/// 本计划的工具错误不走错误码，而是走 `isError: true` 的 content。
const int kJsonRpcParseError = -32700;
const int kJsonRpcInvalidRequest = -32600;
const int kJsonRpcMethodNotFound = -32601;
const int kJsonRpcInvalidParams = -32602;
const int kJsonRpcInternalError = -32603;

class JsonRpcError implements Exception {
  const JsonRpcError(this.code, this.message, [this.data]);

  final int code;
  final String message;
  final Object? data;

  Map<String, Object?> toJson() => <String, Object?>{
        'code': code,
        'message': message,
        if (data != null) 'data': data,
      };
}

class JsonRpcResponse {
  const JsonRpcResponse.result(this.id, this.result) : error = null;
  const JsonRpcResponse.error(this.id, this.error) : result = null;

  final Object? id;
  final Object? result;
  final JsonRpcError? error;

  Map<String, Object?> toJson() => <String, Object?>{
        'jsonrpc': '2.0',
        'id': id,
        if (error != null) 'error': error!.toJson() else 'result': result,
      };
}

/// MCP 消息分发器：输入已解码的 JSON，输出待序列化的响应体。
///
/// 不持有 socket、不依赖 dart:io，便于纯单测覆盖协议行为。
class McpDispatcher {
  McpDispatcher({
    required this.serverName,
    required this.serverVersion,
    required this.tools,
    this.instructions,
  });

  static const List<String> supportedProtocolVersions = <String>[
    '2025-06-18',
    '2025-03-26',
    '2024-11-05',
  ];
  static const String latestProtocolVersion = '2025-06-18';

  final String serverName;
  final String serverVersion;
  final McpToolRegistry tools;
  final String? instructions;

  String _protocolVersion = latestProtocolVersion;

  /// 最近一次 initialize 协商出的版本（HTTP 层写 MCP-Protocol-Version 头用）。
  String get protocolVersion => _protocolVersion;

  /// 返回待序列化响应体：`Map`（单条）/ `List`（批量）/ `null`（通知，202 空包）。
  Future<Object?> handle(Object? message) async {
    if (message is List) {
      final out = <Object?>[];
      for (final item in message) {
        final one = await _handleOne(item);
        if (one != null) out.add(one.toJson());
      }
      return out.isEmpty ? null : out;
    }
    return (await _handleOne(message))?.toJson();
  }

  Future<JsonRpcResponse?> _handleOne(Object? message) async {
    if (message is! Map) {
      return const JsonRpcResponse.error(
        null,
        JsonRpcError(kJsonRpcInvalidRequest, 'Request must be a JSON object'),
      );
    }
    final map = message as Map<String, dynamic>;
    final id = map['id'];
    final method = map['method'];
    if (method is! String) {
      return JsonRpcResponse.error(
        id,
        const JsonRpcError(kJsonRpcInvalidRequest, 'Missing "method"'),
      );
    }
    try {
      final result = await _dispatch(method, map['params']);
      if (id == null) return null; // 通知不回包
      return JsonRpcResponse.result(id, result);
    } on JsonRpcError catch (e) {
      return id == null ? null : JsonRpcResponse.error(id, e);
    } catch (e) {
      return id == null
          ? null
          : JsonRpcResponse.error(
              id,
              JsonRpcError(kJsonRpcInternalError, 'Internal error', e.toString()),
            );
    }
  }

  Future<Object?> _dispatch(String method, Object? params) async {
    switch (method) {
      case 'initialize':
        return _initialize(params);
      case 'ping':
        return <String, Object?>{};
      case 'tools/list':
        return _toolsList();
      case 'tools/call':
        return _toolsCall(params);
      case 'notifications/initialized':
      case 'notifications/cancelled':
      case 'notifications/progress':
        return null;
      default:
        throw const JsonRpcError(kJsonRpcMethodNotFound, 'Method not found');
    }
  }

  Map<String, Object?> _initialize(Object? params) {
    final requested =
        params is Map ? params['protocolVersion'] as String? : null;
    _protocolVersion = requested != null && supportedProtocolVersions.contains(requested)
        ? requested
        : latestProtocolVersion;
    return <String, Object?>{
      'protocolVersion': _protocolVersion,
      'capabilities': <String, Object?>{
        'tools': <String, Object?>{'listChanged': false},
      },
      'serverInfo': <String, Object?>{
        'name': serverName,
        'version': serverVersion,
      },
      if (instructions != null) 'instructions': instructions,
    };
  }

  Map<String, Object?> _toolsList() => <String, Object?>{
        'tools': tools
            .visibleTools()
            .map((t) => t.toJson())
            .toList(growable: false),
      };

  Future<Map<String, Object?>> _toolsCall(Object? params) async {
    final p = params is Map ? params as Map<String, dynamic> : null;
    final name = p?['name'] as String?;
    final rawArgs = p?['arguments'];
    final args = rawArgs is Map
        ? Map<String, Object?>.from(rawArgs)
        : <String, Object?>{};
    if (name == null) {
      throw const JsonRpcError(kJsonRpcInvalidParams, 'Missing "name"');
    }
    final result = await tools.execute(name, args);
    return <String, Object?>{
      'content': <Object?>[
        <String, Object?>{'type': 'text', 'text': result.text},
      ],
      'isError': result.isError,
    };
  }
}
