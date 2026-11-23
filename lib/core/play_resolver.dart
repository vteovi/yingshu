import 'dart:convert';

import 'package:dio/dio.dart';

/// 播放地址解析：把「网页播放页」换成真正的视频流地址。
///
/// 很多采集站的 `vod_play_url` 给的是形如 `https://hd.xxx.com/play/abcd` 的播放页，
/// 页面里用 hls.js 动态加载 `const vid = 'https://hd.xxx.com/play/abcd/index.m3u8';`。
/// 直接把播放页丢给 ExoPlayer 只会得到 `VideoError ... Source error`，
/// 所以这里先在 Dart 侧把 m3u8 挖出来再交给播放器。
class PlayResolver {
  PlayResolver({Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 10),
              receiveTimeout: const Duration(seconds: 15),
              followRedirects: true,
              maxRedirects: 4,
            ));

  final Dio _dio;

  static final RegExp _mediaRe = RegExp(
    r'\.(?:m3u8|mp4|flv|ts|mkv|mov)(?:[?#]|$)',
    caseSensitive: false,
  );

  /// 明显就是视频流 / 直链，直接用。
  static bool looksLikeMedia(String url) => _mediaRe.hasMatch(url.trim());

  /// 返回可直接播放的地址；解析不出来时退回原地址（让播放器把真实错误报出来）。
  Future<String> resolve(String url, {String userAgent = ''}) async {
    final raw = url.trim();
    if (raw.isEmpty) return raw;
    if (looksLikeMedia(raw)) return raw;

    // 少数站点的播放页地址本身就是 m3u8，只是没有扩展名：先试一次 HEAD
    try {
      final head = await _dio.head<String>(
        raw,
        options: Options(
          headers: {if (userAgent.isNotEmpty) 'User-Agent': userAgent},
          validateStatus: (s) => s != null && s < 500,
          receiveTimeout: const Duration(seconds: 8),
        ),
      );
      final type = (head.headers.value('content-type') ?? '').toLowerCase();
      if (type.contains('mpegurl') || type.contains('video/') || type.contains('octet-stream')) {
        return raw;
      }
    } catch (_) {
      // HEAD 不被支持时继续走页面解析
    }

    String body;
    try {
      final response = await _dio.get<String>(
        raw,
        options: Options(
          responseType: ResponseType.plain,
          headers: {if (userAgent.isNotEmpty) 'User-Agent': userAgent},
          validateStatus: (s) => s != null && s < 500,
        ),
      );
      body = response.data ?? '';
    } catch (_) {
      return raw;
    }
    if (body.trim().isEmpty) return raw;

    final extracted = extractMediaUrl(body);
    return extracted ?? raw;
  }

  /// 从播放页 HTML 里抽出媒体地址（支持 hls.js 的 `const vid = '...'` 与裸链接）。
  static String? extractMediaUrl(String html) {
    final quoted = RegExp(
      r'''["'](https?://[^"'\\\s]+\.(?:m3u8|mp4|flv)[^"'\\\s]*)["']''',
      caseSensitive: false,
    );
    final quotedMatch = quoted.firstMatch(html);
    if (quotedMatch != null) return _decode(quotedMatch.group(1)!);

    final bare = RegExp(
      r'''https?://[^\s"'<>()\\]+\.(?:m3u8|mp4|flv)(?:[?#][^\s"'<>()\\]*)?''',
      caseSensitive: false,
    );
    final bareMatch = bare.firstMatch(html);
    if (bareMatch != null) return _decode(bareMatch.group(0)!);

    // 有些页面把地址写成 json 里的 "url":"..."（不带扩展名的流地址也能命中 m3u8 字段名）
    final jsonUrl = RegExp(
      r'''["'](?:url|src|video|playUrl|m3u8)["']\s*:\s*["'](https?://[^"']+)["']''',
      caseSensitive: false,
    );
    final jsonMatch = jsonUrl.firstMatch(html);
    if (jsonMatch != null) return _decode(jsonMatch.group(1)!);
    return null;
  }

  static String _decode(String value) {
    var text = value
        .replaceAll(r'\/', '/')
        .replaceAll(r'\u0026', '&')
        .replaceAll('&amp;', '&');
    // 有些站点用 JSON 转义过的字符串
    if (text.contains(r'\u')) {
      try {
        text = jsonDecode('"${text.replaceAll('"', r'\"')}"') as String;
      } catch (_) {}
    }
    return text;
  }
}
