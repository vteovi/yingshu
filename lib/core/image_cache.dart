import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'image_util.dart';

/// 海报磁盘缓存：按 URL + 解码宽度算一个稳定文件名，直接落在应用私有目录。
///
/// 之前的做法是走 flutter_cache_manager（内部用 JSON/sqlite 记索引 + 过期判断），
/// 每次冷启动要逐张查索引，海报列表十几二十张就是十几二十次异步查询，
/// 表现就是「先空白一会儿才出图」。这里改成：
/// 文件名就能直接算出来 → 命中就是一次磁盘读，没命中才下载，
/// 下载写盘后再后台检查是否需要刷新，旧图也能先出。
class PosterFileCache {
  PosterFileCache._();

  static Directory? _dir;

  /// 图片超过这个时长会后台重新拉一次，下次启动就能看到新图。
  static const Duration refreshAfter = Duration(days: 7);

  /// 最多保留这么多张海报文件，超了按修改时间删最旧的。
  static const int maxFiles = 2500;

  static Future<Directory> _ensureDir() async {
    final cached = _dir;
    if (cached != null) return cached;
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}${Platform.pathSeparator}poster_cache');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    _dir = dir;
    return dir;
  }

  /// FNV-1a 双向哈希，保证同名 URL 永远落到同一个文件名（跨进程稳定）。
  static String _hashName(String input) {
    var a = 0x811c9dc5;
    var b = 0x811c9dc5;
    for (final unit in input.codeUnits) {
      a = ((a ^ unit) * 0x01000193) & 0xFFFFFFFF;
    }
    for (final unit in input.codeUnits.reversed) {
      b = ((b ^ unit) * 0x01000193) & 0xFFFFFFFF;
    }
    return '${a.toRadixString(16).padLeft(8, '0')}${b.toRadixString(16).padLeft(8, '0')}';
  }

  static Future<File> fileFor(String url, int width) async {
    final dir = await _ensureDir();
    final name = '${_hashName('$url@$width')}.img';
    return File('${dir.path}${Platform.pathSeparator}$name');
  }

  static final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 12),
      receiveTimeout: const Duration(seconds: 25),
      responseType: ResponseType.bytes,
      followRedirects: true,
      validateStatus: (code) => code != null && code >= 200 && code < 400,
    ),
  );

  /// 下载并写盘；失败返回 null。
  static Future<Uint8List?> download(
    String url,
    int width,
    Map<String, String>? headers,
  ) async {
    try {
      final response = await _dio.get<List<int>>(
        url,
        options: Options(headers: headers),
      );
      final data = response.data;
      if (data == null || data.isEmpty) return null;
      final bytes = Uint8List.fromList(data);
      final file = await fileFor(url, width);
      final temp = File('${file.path}.tmp');
      await temp.writeAsBytes(bytes, flush: true);
      await temp.rename(file.path);
      return bytes;
    } catch (_) {
      return null;
    }
  }

  /// 启动时在后台修剪缓存目录，别让它无限长大。
  static Future<void> prune() async {
    try {
      final dir = await _ensureDir();
      final files = <FileSystemEntity>[];
      await for (final entity in dir.list()) {
        if (entity is File && entity.path.endsWith('.img')) files.add(entity);
      }
      if (files.length <= maxFiles) return;
      final stats = <MapEntry<FileSystemEntity, DateTime>>[];
      for (final file in files) {
        try {
          stats.add(MapEntry(file, (await file.stat()).modified));
        } catch (_) {}
      }
      stats.sort((a, b) => a.value.compareTo(b.value));
      final toDelete = stats.length - maxFiles;
      for (var i = 0; i < toDelete; i++) {
        try {
          await stats[i].key.delete();
        } catch (_) {}
      }
    } catch (_) {}
  }

  /// 清空所有海报缓存（设置页「清除海报缓存」用）。
  static Future<void> clear() async {
    try {
      final dir = await _ensureDir();
      await for (final entity in dir.list()) {
        try {
          await entity.delete();
        } catch (_) {}
      }
    } catch (_) {}
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  }
}

/// 海报图片来源：先读磁盘缓存，立即出图；磁盘没有才联网，写盘留给下次。
///
/// 走 ImageProvider 而不是 CachedNetworkImage，是因为解码结果会进 Flutter 的
/// 内存缓存：同一个 URL 在切标签、返回上一页时直接命中，不会闪一下空白。
@immutable
class PosterImageProvider extends ImageProvider<PosterImageProvider> {
  const PosterImageProvider(
    this.url, {
    this.headers,
    this.width = 480,
  });

  final String url;
  final Map<String, String>? headers;
  final int width;

  @override
  Future<PosterImageProvider> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture<PosterImageProvider>(this);
  }

  @override
  ImageStreamCompleter loadImage(
    PosterImageProvider key,
    ImageDecoderCallback decode,
  ) {
    return MultiFrameImageStreamCompleter(
      codec: _load(decode),
      scale: 1,
      debugLabel: 'Poster($url)',
      informationCollector: () => <DiagnosticsNode>[
        DiagnosticsProperty<String>('URL', url, style: DiagnosticsTreeStyle.errorProperty),
      ],
    );
  }

  Future<ui.Codec> _load(ImageDecoderCallback decode) async {
    Uint8List? bytes;
    final file = await PosterFileCache.fileFor(url, width);
    try {
      if (await file.exists()) {
        bytes = await file.readAsBytes();
        if (bytes.isEmpty) {
          bytes = null;
        } else {
          final modified = (await file.stat()).modified;
          if (DateTime.now().difference(modified) > PosterFileCache.refreshAfter) {
            // 有缓存就先显示，顺手在后台换成最新图，不阻塞这次绘制。
            unawaited(PosterFileCache.download(url, width, headers));
          }
        }
      }
    } catch (_) {
      bytes = null;
    }

    bytes ??= await PosterFileCache.download(url, width, headers);
    if (bytes == null || bytes.isEmpty) {
      throw HttpException('海报加载失败', uri: Uri.parse(url));
    }
    return decode(
      await ui.ImmutableBuffer.fromUint8List(bytes),
      getTargetSize: (int intrinsicWidth, int intrinsicHeight) {
        if (width <= 0 || intrinsicWidth <= width) {
          return ui.TargetImageSize(width: intrinsicWidth, height: intrinsicHeight);
        }
        final w = width;
        final h = (intrinsicHeight * width / intrinsicWidth).round();
        return ui.TargetImageSize(width: w, height: h);
      },
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is PosterImageProvider &&
        other.url == url &&
        other.width == width &&
        mapEquals(other.headers, headers);
  }

  @override
  int get hashCode => Object.hash(url, width, headers?.length);
}

/// 把 Flutter 解码后的图片内存缓存调大。
///
/// 默认只有 1000 张 / 100MB，海报一屏就是十几张高清图，很容易被挤出去，
/// 结果每次切标签、返回上一页都要重新解码，肉眼看就是「又在加载海报」。
void tuneImageMemoryCache() {
  final cache = PaintingBinding.instance.imageCache;
  cache.maximumSize = 3000;
  cache.maximumSizeBytes = 320 * 1024 * 1024;
}

/// 已经进过内存缓存的海报地址，避免同一个列表反复 precache。
final Set<String> _precached = <String>{};

/// 预取一批海报到内存 + 磁盘缓存，让列表首帧就能直接画出来。
///
/// 只在列表数据加载完成后调用一次，串行 4 张并发，避免抢带宽拖慢列表请求。
Future<void> precachePosters(
  BuildContext context,
  Iterable<String> pictureUrls, {
  String? api,
}) async {
  final urls = <String>{};
  for (final raw in pictureUrls) {
    final url = normalizeImageUrl(raw, api: api);
    if (url.isNotEmpty && (url.startsWith('http://') || url.startsWith('https://'))) {
      urls.add(url);
    }
  }
  urls.removeAll(_precached);
  if (urls.isEmpty) return;
  _precached.addAll(urls);

  final headers = imageHeadersFor(api);
  final providers = urls
      .map((url) => PosterImageProvider(
            url,
            headers: headers.isEmpty ? null : headers,
            // 必须和 VodCard 里用的参数完全一致，否则内存缓存 key 不同、预取等于白做。
            width: 480,
          ))
      .toList(growable: false);

  for (var i = 0; i < providers.length; i += 4) {
    final batch = providers.skip(i).take(4);
    await Future.wait(batch.map((provider) async {
      try {
        await precacheImage(provider, context);
      } catch (_) {
        // 单张失败不影响其他海报。
      }
    }));
  }
}
