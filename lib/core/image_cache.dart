import 'package:flutter_cache_manager/flutter_cache_manager.dart';

/// 海报图磁盘缓存。
///
/// [CachedNetworkImage] 默认用的是全局 [DefaultCacheManager]：只保留 200 个文件、
/// 30 天过期。海报列表一翻几页，前面的图就被挤掉了，所以单独建一个大容量的
/// 缓存池：3000 张 / 90 天，实际占用通常在几十到一两百 MB 量级。
class PosterCacheManager {
  PosterCacheManager._();

  static const String key = 'yingshuPosterCache';

  static final CacheManager instance = CacheManager(
    Config(
      key,
      stalePeriod: const Duration(days: 90),
      maxNrOfCacheObjects: 3000,
      repo: JsonCacheInfoRepository(databaseName: key),
      fileService: HttpFileService(),
    ),
  );

  /// 清空海报缓存（设置页「清除海报缓存」用）。
  static Future<void> clear() => instance.emptyCache();
}
