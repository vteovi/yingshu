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

  /// TVBox 站点常把配置放在这些路径下，根域名只是首页（"站点创建成功"那种）。
  static const List<String> configPathHints = [
    'index.php',
    'config.json',
    'box.json',
    'tvbox.json',
    'api.json',
    '1.json',
    'config.txt',
    'box.txt',
  ];

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

    var bundle = parseSourceBundle(body);

    // 根路径很可能只是一个首页 HTML：先找页面里的配置链接，再试几个常见配置路径
    if (bundle.isEmpty && depth == 0 && _looksLikeHtml(body)) {
      for (final candidate in _configCandidates(body, uri)) {
        if (!seen.add(candidate)) continue;
        try {
          final text = await _download(candidate);
          if (text.trim().isEmpty) continue;
          final parsed = parseSourceBundle(text);
          if (parsed.isEmpty) continue;
          bundle = parsed;
          break;
        } catch (_) {
          // 这个路径不通，试下一个
        }
      }
    }

    if (bundle.isEmpty) {
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

  static bool _looksLikeHtml(String text) {
    final head = text.trimLeft().toLowerCase();
    return head.startsWith('<!doctype') ||
        head.startsWith('<html') ||
        head.contains('<body') ||
        head.contains('<head');
  }

  /// 从首页 HTML 里找配置候选地址：页面上的链接优先，再补一组常见配置路径。
  List<String> _configCandidates(String html, Uri base) {
    final out = <String>[];
    final seen = <String>{};

    void add(Uri uri) {
      final full = uri.toString();
      if (!full.startsWith('http')) return;
      if (seen.add(full) && !out.contains(full)) out.add(full);
    }

    final attrRe = RegExp(
      r'''(?:href|src|data-url|data-src)\s*=\s*["']([^"']+)["']''',
      caseSensitive: false,
    );
    final hintRe = RegExp(
      r'(?:tvbox|config|api\.php|provide/vod|\.json|\.txt)',
      caseSensitive: false,
    );
    final assetRe = RegExp(
      r'\.(?:css|js|mjs|png|jpe?g|gif|webp|svg|ico|woff2?|ttf|mp4|m3u8|html?)(?:[?#]|$)',
      caseSensitive: false,
    );

    for (final match in attrRe.allMatches(html)) {
      final raw = match.group(1)!.trim();
      if (raw.isEmpty || raw.startsWith('#') || raw.startsWith('javascript:')) continue;
      final lower = raw.toLowerCase();
      if (!hintRe.hasMatch(lower) || assetRe.hasMatch(lower)) continue;
      try {
        add(base.resolve(raw));
      } catch (_) {}
    }

    // 页面跳转 / 脚本里直接写死的配置地址
    for (final match in RegExp("https?://[^\\s\"'<>()]+", caseSensitive: false).allMatches(html)) {
      final raw = match.group(0)!;
      if (hintRe.hasMatch(raw) && !assetRe.hasMatch(raw)) {
        try {
          add(Uri.parse(raw));
        } catch (_) {}
      }
    }

    for (final hint in configPathHints) {
      try {
        add(base.resolve(hint));
      } catch (_) {}
    }

    // 根路径本来就没路径时，优先试根下的固定名字
    return out.take(10).toList(growable: false);
  }
}
