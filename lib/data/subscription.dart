import 'package:dio/dio.dart';

import '../core/constants.dart';
import '../models/cms_source.dart';
import 'tvbox_config.dart';

/// 订阅地址 / 订阅文本解析，兼容影枢自有格式和 TVBox 配置格式。
List<CmsSource> parseSubscriptionText(String text) => parseSourceBundle(text).sources;

/// 从远端订阅链接（或本地配置文件内容）拉取源列表。
class SubscriptionFetcher {
  SubscriptionFetcher({Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 12),
              receiveTimeout: const Duration(seconds: 25),
            ));

  final Dio _dio;

  /// 下载订阅配置时使用的 UA，跟随设置页里的「请求 User-Agent」。
  String userAgent = kDefaultUserAgent;

  /// 最大嵌套层数：TVBox 的 urls 常常指向另一个配置。
  static const int maxDepth = 3;

  Future<List<CmsSource>> fetch(String url) async {
    final bundle = await fetchBundle(url);
    return bundle.sources;
  }

  Future<SourceBundle> fetchBundle(String url, {int depth = 0, Set<String>? visited}) async {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      throw Exception('订阅地址不合法');
    }
    final seen = visited ?? <String>{};
    if (!seen.add(uri.toString())) return const SourceBundle();

    final body = await _download(uri.toString());
    if (body.trim().isEmpty) throw Exception('订阅内容为空');

    final bundle = parseSourceBundle(body);
    if (bundle.sources.isEmpty && bundle.subscriptionUrls.isEmpty) {
      final hint = describeUnsupportedBody(body);
      throw Exception(hint ?? '未从订阅内容中解析到接口地址');
    }

    final sources = <CmsSource>[...bundle.sources];
    if (depth + 1 < maxDepth) {
      for (final nested in bundle.subscriptionUrls) {
        try {
          final child = await fetchBundle(nested, depth: depth + 1, visited: seen);
          sources.addAll(child.sources);
        } catch (_) {
          // 单个子订阅失败不影响整体导入
        }
      }
    }
    return SourceBundle(sources: sources, subscriptionUrls: bundle.subscriptionUrls);
  }

  Future<String> _download(String url) async {
    final response = await _dio.get<String>(
      url,
      options: Options(
        responseType: ResponseType.plain,
        headers: {
          'User-Agent': userAgent.trim().isEmpty ? kDefaultUserAgent : userAgent.trim(),
        },
      ),
    );
    return response.data ?? '';
  }
}
