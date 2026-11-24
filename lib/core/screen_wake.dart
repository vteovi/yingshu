import 'package:flutter/services.dart';

/// 播放时保持屏幕常亮（走后原生 FLAG_KEEP_SCREEN_ON）。
///
/// 用引用计数，避免多个播放页/画中画来回切时把标志提前清掉。
class ScreenWake {
  ScreenWake._();

  static const MethodChannel _channel = MethodChannel('com.yingshu.player/screen');
  static int _refCount = 0;

  static Future<void> acquire() async {
    _refCount++;
    if (_refCount != 1) return;
    await _set(true);
  }

  static Future<void> release() async {
    if (_refCount > 0) _refCount--;
    if (_refCount != 0) return;
    await _set(false);
  }

  static Future<void> _set(bool on) async {
    try {
      await _channel.invokeMethod<bool>('keepOn', {'on': on});
    } on MissingPluginException {
      // 桌面端 / 老版本没有这个通道，忽略即可
    } on PlatformException {
      // 某些定制 ROM 不允许改标志位，忽略
    }
  }
}
