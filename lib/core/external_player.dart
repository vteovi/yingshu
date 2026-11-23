import 'package:flutter/services.dart';

/// 「用第三方播放器打开」：把解析后的视频地址交给系统 Intent，
/// 由用户在 VLC / MX Player / 系统播放器中选择一个播放。
class ExternalPlayer {
  ExternalPlayer._();

  static const MethodChannel _channel =
      MethodChannel('com.yingshu.player/external_player');

  static Future<void> open(String url, {String title = ''}) async {
    await _channel.invokeMethod<bool>('open', {
      'url': url,
      'title': title,
    });
  }
}
