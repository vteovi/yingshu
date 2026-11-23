import 'package:flutter/services.dart';

/// Android 系统级「画中画」（Picture-in-Picture）通道。
///
/// 进入后整个播放页会被系统缩成小窗叠在桌面/其他 App 上，
/// 退出小窗（点小窗里的全屏按钮）会回到 App 的播放页。
class Pip {
  Pip._();

  static const MethodChannel _channel = MethodChannel('com.yingshu.player/pip');
  static bool? _supported;
  static void Function(bool inPip)? _listener;

  /// 当前设备是否支持画中画。
  static Future<bool> isSupported() async {
    if (_supported != null) return _supported!;
    try {
      final value = await _channel.invokeMethod<bool>('isSupported');
      _supported = value ?? false;
    } catch (_) {
      _supported = false;
    }
    return _supported!;
  }

  /// 进入画中画。[aspectRatio] 传视频本身的宽高比（小于 1 表示竖屏）。
  static Future<bool> enter({required double aspectRatio}) async {
    final ratio = (!aspectRatio.isFinite || aspectRatio <= 0) ? 16 / 9 : aspectRatio;
    try {
      final ok = await _channel.invokeMethod<bool>('enter', {
        'aspectRatio': ratio,
      });
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 监听画中画状态变化（进入 / 退出）。
  static void listen(void Function(bool inPip) listener) {
    _listener = listener;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'pipChanged') {
        _listener?.call(call.arguments == true);
      }
      return null;
    });
  }

  static void clearListener() {
    _listener = null;
  }
}
