import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

import 'image_util.dart';

/// 海报图磁盘缓存。
///
/// [CachedNetworkImage] 默认用的是全局 [DefaultCacheManager]：只保留 200 个文件、
/// 30 天过期。海报列表一翻几页，前面的图就被挤掉了，所以单独建一个大容量的
/// 缓存池：6000 张 / 180 天，实际占用通常在几十到几百 MB 量级。
class PosterCacheManager {
  PosterCacheManager._();

  static const String key = 'yingshuPosterCache';

  static final CacheManager instance = CacheManager(
    Config(
      key,
      stalePeriod: const Duration(days: 180),
      maxNrOfCacheObjects: 6000,
      repo: JsonCacheInfoRepository(databaseName: key),
      fileService: HttpFileService(),
    ),
  );

  /// 清空海报缓存（设置页「清除海报缓存」用）。
  static Future<void> clear() => instance.emptyCache();
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
/// 只在列表数据加载完成后调用一次，串行 3 张并发，避免抢带宽拖慢列表请求。
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
  final providerList = urls
      .map((url) => CachedNetworkImageProvider(
            url,
            cacheManager: PosterCacheManager.instance,
            headers: headers.isEmpty ? null : headers,
            // 必须和 VodCard 里用的参数完全一致，否则内存缓存 key 不同、预取等于白做。
            maxWidth: 480,
          ))
      .toList(growable: false);

  for (var i = 0; i < providerList.length; i += 4) {
    final batch = providerList.skip(i).take(4);
    await Future.wait(batch.map((provider) async {
      try {
        await precacheImage(provider, context);
      } catch (_) {
        // 单张失败不影响其他海报。
      }
    }));
  }
}
