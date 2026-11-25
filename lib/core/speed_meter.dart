import 'dart:async';
import 'dart:io';

/// 实时下载速度采样器。
///
/// 播放内核（ExoPlayer / video_player）不把带宽统计暴露给 Flutter，
/// 所以这里另开一条轻量连接去「量」真实吞吐：每隔几秒对片源地址发一次
/// 带 Range 的 GET，读满 [_maxSampleBytes] 就断开，用「字节数 ÷ 耗时」算出速率。
///
/// - 片源是 m3u8 时，第一次会顺带解析出首个分片地址，之后量的是分片（真实码流路径）；
/// - 采样只用 128~192 KB，对流量影响很小，而且默认由设置里的开关控制是否启用；
/// - 结果做指数平滑，避免数字每秒乱跳。
class SpeedMeter {
  SpeedMeter({
    required String url,
    required this.userAgent,
    this.onSample,
    this.interval = const Duration(seconds: 5),
    this.maxSampleBytes = 192 * 1024,
  }) : _target = url;

  final String userAgent;
  final Duration interval;
  final int maxSampleBytes;

  /// 每秒回调一次平滑后的速率（字节/秒）。首次成功采样之前不回调。
  final void Function(double bytesPerSecond)? onSample;

  String _target;
  Timer? _timer;
  HttpClient? _client;
  bool _sampling = false;
  bool _stopped = false;
  double? _smoothed;
  bool _resolvedPlaylist = false;

  /// 最近一次平滑后的速率（字节/秒），没测到时为 null。
  double? get bytesPerSecond => _smoothed;

  Future<void> start() async {
    if (_stopped || _timer != null) return;
    _client ??= HttpClient()
      ..connectionTimeout = const Duration(seconds: 4)
      ..autoUncompress = true;
    // 先立刻量一次，别让用户盯着空白的「--」等 5 秒
    unawaited(_sample());
    _timer = Timer.periodic(interval, (_) => unawaited(_sample()));
  }

  Future<void> stop() async {
    _stopped = true;
    _timer?.cancel();
    _timer = null;
    _client?.close(force: true);
    _client = null;
  }

  Future<void> _sample() async {
    if (_sampling || _stopped) return;
    final client = _client;
    if (client == null) return;
    _sampling = true;
    try {
      final result = await _measure(client, _target, maxSampleBytes);
      if (_stopped || result == null) return;
      if (result.playlistUrl != null && !_resolvedPlaylist) {
        // 量到的是播放列表：换成第一个分片再量，那个才是真正在下的数据
        _resolvedPlaylist = true;
        _target = result.playlistUrl!;
        final again = await _measure(client, _target, maxSampleBytes);
        if (!_stopped && again != null) _emit(again.bytesPerSecond);
        return;
      }
      _emit(result.bytesPerSecond);
    } catch (_) {
      // 网络抖动、地址过期都当作这次没量到，保留上一次的数字
    } finally {
      _sampling = false;
    }
  }

  void _emit(double bytesPerSecond) {
    if (_stopped || bytesPerSecond <= 0) return;
    final previous = _smoothed;
    _smoothed = previous == null
        ? bytesPerSecond
        : previous * 0.6 + bytesPerSecond * 0.4;
    onSample?.call(_smoothed!);
  }

  Future<_SampleResult?> _measure(HttpClient client, String url, int cap) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return null;
    final request = await client.getUrl(uri);
    request.headers.set(HttpHeaders.userAgentHeader, userAgent);
    request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-${cap - 1}');
    final response = await request.close();
    if (response.statusCode >= 400) {
      await response.drain<void>();
      return null;
    }
    final stopwatch = Stopwatch()..start();
    var bytes = 0;
    final head = <int>[];
    await for (final chunk in response) {
      bytes += chunk.length;
      if (bytes <= 512) head.addAll(chunk.take(512 - head.length));
      if (bytes >= cap) break;
    }
    stopwatch.stop();
    if (bytes <= 0) return null;

    final text = String.fromCharCodes(head);
    final looksPlaylist = text.trimLeft().startsWith('#EXTM3U');
    if (looksPlaylist) {
      final segment = _firstSegmentUrl(text, uri);
      if (segment != null) {
        return _SampleResult(bytesPerSecond: 0, playlistUrl: segment);
      }
      return null;
    }
    final elapsedMs = stopwatch.elapsedMilliseconds;
    if (elapsedMs <= 0) return null;
    // 只读到几百字节就 EOF：可能是连接被掐断，这种数字不可信
    if (bytes < 8 * 1024) return null;
    return _SampleResult(bytesPerSecond: bytes * 1000 / elapsedMs);
  }

  /// 从 m3u8 文本里取第一个真正的分片地址（跳过注释与 KEY 行），按基地址补全相对路径。
  static String? _firstSegmentUrl(String playlist, Uri base) {
    for (final raw in playlist.split('\n')) {
      final line = raw.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      final resolved = base.resolve(line);
      return resolved.toString();
    }
    return null;
  }
}

class _SampleResult {
  const _SampleResult({required this.bytesPerSecond, this.playlistUrl});

  final double bytesPerSecond;
  final String? playlistUrl;
}
