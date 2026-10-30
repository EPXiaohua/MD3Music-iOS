import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/utils/app_toast.dart' as toast_util;
import '../../data/repositories/settings_repository.dart';
import 'depth_engine.dart';

/// 原生 MethodChannel 后端（Android / TV / iOS）。
///
/// Android 的通道协议由 `DepthCoverPlugin.kt` 实现；iOS 由
/// `DepthCoverPlugin.swift` 实现同名协议（模型从 bundle 读取，不走
/// APK 内置资产提取，loadModel 的 modelAsset 只取 basename）。
/// standard 包（未编译 DepthCoverPlugin）走 MissingPluginException 分支，
/// 属预期降级，不提示、不重试刷日志。
class ChannelDepthEngine implements DepthEngine {
  static const _channel =
      MethodChannel('com.md3music.md3music/depth_cover');

  /// 内置模型的资产路径（原生自动从 APK 提取到应用目录）。
  static const String _modelAsset = 'models/depth_anything_v2_vits_q4f16.onnx';

  /// 历史版本遗留的模型文件名（取消导入功能后为孤儿文件，加载时顺带清理）。
  static const List<String> _legacyModelFileNames = [
    'depth_anything_v2_vits.onnx',        // fp32 导入版（取消导入前）
    'depth_anything_v2_vits_fp16.onnx',   // fp16 内置版（q4f16 之前）
  ];

  /// 原生侧是否已 loadModel（仅当前进程会话有效）。
  bool _modelLoaded = false;

  /// 神经修补（MI-GAN）会话是否已加载（进程内一次；开关开启时才加载）。
  bool _inpaintLoaded = false;

  /// 模型加载失败的进程级一次性提示（避免每首歌都弹）。
  static bool _loadFailureToastShown = false;

  @override
  Future<void> showToast(String message) async {
    // iOS 原生侧的 showToast 只会打系统日志（无系统 toast），用户完全
    // 看不到失败原因，表现为「开了开关但封面没有 3D」。改走 app 内
    // fluttertoast（iOS 有实现）。Android 仍走原生通道（fluttertoast 与
    // 原生 DepthCoverPlugin 的 toast 会重复弹）。
    if (!kIsWeb && Platform.isIOS) {
      toast_util.showToast(message, long: true);
      return;
    }
    try {
      await _channel.invokeMethod<void>('showToast', {'message': message});
    } on PlatformException {
      // 忽略：通道未注册或原生侧异常都不应影响主流程
    } on MissingPluginException {
      // standard 包无 DepthCoverPlugin 属正常
    }
  }

  void _notifyLoadFailureOnce([String? detail]) {
    if (_loadFailureToastShown) return;
    _loadFailureToastShown = true;
    // ignore: discarded_futures
    showToast(
        detail == null ? '3D 封面模型初始化失败' : '3D 封面模型初始化失败: $detail');
  }

  @override
  Future<bool> ensureModelLoaded() async {
    if (_modelLoaded) return true;
    try {
      final loaded = await _channel.invokeMethod<bool>('isModelLoaded');
      if (loaded == true) {
        _modelLoaded = true;
        return true;
      }
      // 优先用用户导入的模型；未导入则用 APK 内置资产（原生自动提取）。
      // 防御：预建模型目录（原生侧提取前也会 mkdirs，双保险；
      // 历史 bug：全新安装该目录不存在 → 提取抛 ENOENT → 3D 永久不可用）。
      final modelDir = Directory(
          '${(await getApplicationSupportDirectory()).path}${Platform.pathSeparator}depth_model');
      try {
        await modelDir.create(recursive: true);
      } catch (e) {
        debugPrint('[DepthCover] 预建模型目录失败: $e');
      }
      // 清理取消导入功能前的历史遗留模型文件（fp32/fp16 旧名，最多 ~149MB）
      for (final name in _legacyModelFileNames) {
        final legacy = File('${modelDir.path}${Platform.pathSeparator}$name');
        if (legacy.existsSync()) {
          try {
            await legacy.delete();
            debugPrint('[DepthCover] 已清理历史遗留模型: ${legacy.path}');
          } catch (_) {}
        }
      }
      final ok = await _channel.invokeMethod<bool>(
        'loadModel',
        {'modelAsset': _modelAsset},
      );
      if (ok == true) {
        _modelLoaded = true;
        return true;
      }
      _notifyLoadFailureOnce();
    } on PlatformException catch (e) {
      debugPrint('[DepthCover] loadModel/isModelLoaded failed: ${e.code} ${e.message}');
      // 具体原因透传给用户（iOS 原生失败此前完全静默，无从排查）
      _notifyLoadFailureOnce(e.message?.isNotEmpty == true ? e.message : e.code);
      return false;
    } on MissingPluginException catch (e) {
      // standard 包无 DepthCoverPlugin（通道未注册）走这里；depth3d 包不应出现。
      debugPrint('[DepthCover] 通道未注册（standard 包属正常）: $e');
      return false;
    }
    return false;
  }

  @override
  Future<void> ensureInpaintSession() async {
    if (_inpaintLoaded) return;
    final enabled = await SettingsRepository().getDepthCoverNeuralInpaint();
    if (!enabled) return;
    try {
      final ok = await _channel.invokeMethod<bool>('loadInpaintModel');
      _inpaintLoaded = ok == true;
      debugPrint('[DepthCover] loadInpaintModel → $_inpaintLoaded');
    } on PlatformException catch (e) {
      debugPrint('[DepthCover] loadInpaintModel failed: ${e.code} ${e.message}');
    } on MissingPluginException catch (_) {
      // standard 包无 DepthCoverPlugin 属正常
    }
  }

  @override
  Future<Map<String, Object?>?> generateDepth(
    String sourcePath,
    String outDir,
    String key,
  ) async {
    try {
      final res = await _channel.invokeMethod<Map<Object?, Object?>>(
        'generateDepth',
        {'sourcePath': sourcePath, 'outDir': outDir, 'key': key},
      );
      if (res == null) {
        debugPrint('[DepthCover] generateDepth → null（同 key 在途）');
        return null;
      }
      final depth = res['depth'];
      final std = res['depthStd'];
      final bgFill = res['bgFill'];
      final inpaint = res['inpaint'];
      if (depth is String && std is double) {
        return {
          'depth': depth,
          'depthStd': std,
          if (bgFill is String) 'bgFill': bgFill,
          if (inpaint is String) 'inpaint': inpaint,
        };
      }
      return null;
    } on PlatformException catch (e) {
      debugPrint('[DepthCover] generateDepth failed: ${e.code} ${e.message}');
      return null;
    }
  }

  @override
  Future<List<String>?> generateLayers(
    String sourcePath,
    String outDir,
    String key,
  ) async {
    try {
      final res = await _channel.invokeMethod<Map<Object?, Object?>>(
        'generate',
        {
          'sourcePath': sourcePath,
          'outDir': outDir,
          'key': key,
        },
      );
      if (res == null) {
        debugPrint('[DepthCover] generate → null（同 key 在途）');
        return null;
      }
      final layers = res['layers'];
      if (layers is List) {
        debugPrint('[DepthCover] generate → ${layers.length} 层');
        return layers.cast<String>();
      }
      return null;
    } on PlatformException catch (e) {
      debugPrint('[DepthCover] generate failed: ${e.code} ${e.message}');
      return null;
    }
  }
}
