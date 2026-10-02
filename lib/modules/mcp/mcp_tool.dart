import 'dart:convert';

/// 工具执行结果。
///
/// - 正常返回用 [McpToolResult.new]：把 [data] JSON 序列化为唯一的 text content。
/// - 错误用 [McpToolResult.error]：`isError=true` 且文本为可读原因（不包 JSON，
///   便于模型直接读懂并自我纠正）。
class McpToolResult {
  const McpToolResult(this.data) : message = null, isError = false;

  const McpToolResult.text(this.message) : data = null, isError = false;

  const McpToolResult.error(this.message) : data = null, isError = true;

  final Object? data;
  final String? message;
  final bool isError;

  String get text => message ?? jsonEncode(data);
}

typedef McpToolHandler = Future<McpToolResult> Function(Map<String, Object?> args);

class McpTool {
  const McpTool({
    required this.name,
    required this.description,
    required this.inputSchema,
    required this.handler,
    this.isMutating = false,
  });

  final String name;
  final String description;

  /// JSON Schema（object 形式），直接透传给 `tools/list`。
  final Map<String, Object?> inputSchema;
  final McpToolHandler handler;

  /// true = 会改变播放状态/队列；只读模式下被注册表拦截。
  final bool isMutating;

  Map<String, Object?> toJson() => <String, Object?>{
        'name': name,
        'description': description,
        'inputSchema': inputSchema,
      };
}

class McpToolRegistry {
  McpToolRegistry(List<McpTool> tools, {this.onCall})
      : _all = List<McpTool>.unmodifiable(tools);

  final List<McpTool> _all;

  /// 每次执行完成后的回调（成功/失败都会触发），供 McpService 记录调用日志。
  final void Function(String tool, bool ok)? onCall;

  /// 只读模式：隐藏并拒绝所有 [McpTool.isMutating] 工具。
  bool readOnly = false;

  List<McpTool> visibleTools() => readOnly
      ? _all.where((t) => !t.isMutating).toList(growable: false)
      : _all;

  McpTool? find(String name) {
    for (final t in _all) {
      if (t.name == name) return t;
    }
    return null;
  }

  /// 统一出口：未知工具 / 只读拦截 / 参数错误 / 执行异常都收敛成 isError 结果。
  Future<McpToolResult> execute(String name, Map<String, Object?> args) async {
    final tool = find(name);
    McpToolResult result;
    if (tool == null) {
      result = McpToolResult.error('未知工具：$name');
    } else if (readOnly && tool.isMutating) {
      result = McpToolResult.error('只读模式已开启，工具 $name 被禁用');
    } else {
      try {
        result = await tool.handler(args);
      } on ArgumentError catch (e) {
        result = McpToolResult.error('参数错误：${e.message}');
      } catch (e) {
        result = McpToolResult.error('执行失败：$e');
      }
    }
    onCall?.call(name, !result.isError);
    return result;
  }
}

String requireString(Map<String, Object?> args, String key) {
  final v = args[key];
  if (v is! String || v.trim().isEmpty) {
    throw ArgumentError('参数 "$key" 必须是非空字符串');
  }
  return v;
}

int requireInt(Map<String, Object?> args, String key, {int? min, int? max}) {
  final v = args[key];
  final n = switch (v) {
    int() => v,
    num() => v.round(),
    _ => null,
  };
  if (n == null) throw ArgumentError('参数 "$key" 必须是整数');
  if (min != null && n < min) throw ArgumentError('参数 "$key" 不能小于 $min');
  if (max != null && n > max) throw ArgumentError('参数 "$key" 不能大于 $max');
  return n;
}

double requireDouble(Map<String, Object?> args, String key,
    {double? min, double? max}) {
  final v = args[key];
  final n = switch (v) {
    num() => v.toDouble(),
    _ => null,
  };
  if (n == null) throw ArgumentError('参数 "$key" 必须是数字');
  if (min != null && n < min) throw ArgumentError('参数 "$key" 不能小于 $min');
  if (max != null && n > max) throw ArgumentError('参数 "$key" 不能大于 $max');
  return n;
}

int optionalInt(Map<String, Object?> args, String key,
    {required int fallback, int? min, int? max}) {
  if (!args.containsKey(key) || args[key] == null) return fallback;
  return requireInt(args, key, min: min, max: max);
}
