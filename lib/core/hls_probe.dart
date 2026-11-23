import 'package:dio/dio.dart';

/// 片头广告探测结果。
class HlsIntro {
  const HlsIntro({required this.adDuration, required this.totalDuration});

  /// 片头广告时长（第一段 discontinuity 之前的内容）。
  final Duration adDuration;

  /// 整条流的总时长（解析不到时为 null）。
  final Duration? totalDuration;

  bool get worthSkipping => adDuration >= const Duration(seconds: 3);
}

/// 探测 m3u8 里有没有「片头广告」。
///
/// 不少采集站把广告当成独立的一段塞进同一条 m3u8，用
/// `#EXT-X-DISCONTINUITY` 把广告和正片切开：
///
/// ```
/// #EXTINF:10.0,
/// ad_01.ts
/// #EXTINF:10.0,
/// ad_02.ts
/// #EXT-X-DISCONTINUITY
/// #EXTINF:600.0,
/// main_01.ts
/// ```
///
/// libmpv 碰到这种「广告 + 正片」拼接的流，常常在广告播完就停住（或错误地
/// 认为整集结束）。这里提前把广告时长算出来，打开后直接 seek 过广告。
Future<HlsIntro?> probeHlsIntro(
  String url, {
  required String userAgent,
  Dio? dio,
}) async {
  final lowered = url.toLowerCase();
  if (!lowered.contains('m3u8') && !lowered.contains('/hls/')) return null;

  final client = dio ??
      Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 8),
        receiveTimeout: const Duration(seconds: 12),
        followRedirects: true,
        maxRedirects: 4,
      ));

  try {
    final text = await _fetch(client, url, userAgent);
    if (text == null) return null;
    return await _parse(text, baseUrl: url, client: client, userAgent: userAgent, depth: 0);
  } catch (_) {
    return null;
  }
}

Future<String?> _fetch(Dio client, String url, String userAgent) async {
  final response = await client.get<String>(
    url,
    options: Options(
      responseType: ResponseType.plain,
      headers: {'User-Agent': userAgent, 'Accept': '*/*'},
      validateStatus: (status) => status != null && status < 400,
    ),
  );
  final body = response.data;
  if (body == null || !body.contains('#EXT')) return null;
  return body;
}

Future<HlsIntro?> _parse(
  String playlist, {
  required String baseUrl,
  required Dio client,
  required String userAgent,
  required int depth,
}) async {
  final lines = playlist.split(RegExp(r'\r?\n'));

  // 主播放列表：挑第一条子流继续解析
  if (playlist.contains('#EXT-X-STREAM-INF') && !playlist.contains('#EXTINF')) {
    if (depth >= 2) return null;
    for (var i = 0; i < lines.length; i++) {
      if (!lines[i].startsWith('#EXT-X-STREAM-INF')) continue;
      final variant = _nextUri(lines, i + 1);
      if (variant == null) continue;
      final resolved = _resolve(baseUrl, variant);
      final child = await _fetch(client, resolved, userAgent);
      if (child == null) continue;
      return await _parse(
        child,
        baseUrl: resolved,
        client: client,
        userAgent: userAgent,
        depth: depth + 1,
      );
    }
    return null;
  }

  var elapsed = 0.0;
  var total = 0.0;
  var sawDiscontinuity = false;
  double? adUntil;

  for (var i = 0; i < lines.length; i++) {
    final line = lines[i].trim();
    if (line.startsWith('#EXTINF:')) {
      final value = line.substring(8).split(',').first.trim();
      final duration = double.tryParse(value) ?? 0;
      if (!sawDiscontinuity) elapsed += duration;
      total += duration;
    } else if (line.startsWith('#EXT-X-DISCONTINUITY')) {
      if (!sawDiscontinuity) {
        sawDiscontinuity = true;
        // 第一段就是正片（或者广告极短），不值得跳
        if (elapsed >= 3 && elapsed <= 300) adUntil = elapsed;
      }
    }
  }

  if (adUntil == null) {
    // 没有 discontinuity：多半是单段正片，不做处理
    return null;
  }

  return HlsIntro(
    adDuration: Duration(milliseconds: (adUntil * 1000).round()),
    totalDuration: total > 0 ? Duration(milliseconds: (total * 1000).round()) : null,
  );
}

String? _nextUri(List<String> lines, int from) {
  for (var i = from; i < lines.length; i++) {
    final line = lines[i].trim();
    if (line.isEmpty) continue;
    if (line.startsWith('#')) {
      // 允许中间夹 EXT-X-STREAM-INF 之类的标签，但不能跨到下一个变体
      if (line.startsWith('#EXT-X-STREAM-INF')) return null;
      continue;
    }
    return line;
  }
  return null;
}

String _resolve(String baseUrl, String relative) {
  final uri = Uri.tryParse(relative);
  if (uri != null && uri.hasScheme) return relative;
  final base = Uri.tryParse(baseUrl);
  if (base == null) return relative;
  return base.resolve(relative).toString();
}
