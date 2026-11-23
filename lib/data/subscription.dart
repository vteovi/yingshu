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

  /// 下载订阅配置时使用的 UA（设置页里的「请求 User-Agent」）。
  String userAgent = kDefaultUserAgent;

  /// 拉配置时依次尝试的 UA。
  ///
  /// 关键：很多 TVBox 配置站**按 UA 分发内容**。带 `okhttp/*` 才返回真配置，
  /// 浏览器 UA 只给一句「站点创建成功」的占位 HTML（`https://box.iqinu.com`
  /// 就是这样：浏览器 UA 拿到 990 字节占位页，okhttp 拿到 46KB 加密配置）。
  /// 所以先用 TVBox 的 UA 试，真的不行再退回用户设置的浏览器 UA。
  static const List<String> configUserAgents = <String>[
    'okhttp/3.15',
    'okhttp/3.12.11',
    'okhttp/4.12.0',
  ];

  /// 配置请求的 Accept，与 TVBox 客户端一致（个别站点也看这个头）。
  static const String _configAccept =
      'text/html,application/xhtml+xml,application/xml;q=0.9,'
      'image/avif,image/webp,image/apng,*/*;q=0.8';

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
    final normalized = _normalizeUrl(url);
    final uri = Uri.tryParse(normalized);
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
    String? fallbackHtml;
    String? firstError;
    // 先按 TVBox 客户端的 UA 试（配置站大多只对 okhttp 放行），再退回用户设置的 UA
    final userAgents = <String>[
      ...configUserAgents,
      if (userAgent.trim().isNotEmpty) userAgent.trim(),
      kDefaultUserAgent,
    ];

    for (final ua in userAgents) {
      try {
        final response = await _dio.get<String>(
          url,
          options: Options(
            responseType: ResponseType.plain,
            headers: {
              'User-Agent': ua,
              'Accept': _configAccept,
            },
          ),
        );
        final body = response.data ?? '';
        if (body.trim().isEmpty) continue;
        // 拿到的是真配置（JSON / 加密十六进制 / 非网页长文本）就用它
        if (_looksLikeConfigPayload(body)) return body;
        fallbackHtml ??= body;
      } catch (error) {
        firstError ??= '$error';
      }
    }
    // 全部 UA 都只拿到网页时，把 HTML 交回去，导航页流程还能从里面找配置链接
    if (fallbackHtml != null) return fallbackHtml;
    throw Exception(firstError ?? '配置拉取失败');
  }

  /// 内容是否像「配置本体」：JSON、TVBox 加密十六进制，或其它非网页文本。
  static bool _looksLikeConfigPayload(String text) {
    final t = text.trim();
    if (t.isEmpty) return false;
    if (t.startsWith('{') || t.startsWith('[')) return true;
    if (t.startsWith('2423') || t.startsWith(r'$#')) return true;
    if (t.length > 200 && !_looksLikeHtml(t) && !t.startsWith('<')) return true;
    return false;
  }

  /// 用户常直接粘贴 `box.iqinu.com` 这种不带协议、甚至带 `http:` 漏斜杠的地址。
  static String _normalizeUrl(String url) {
    var value = url.trim();
    if (value.isEmpty) return value;
    if (value.startsWith('//')) return 'https:$value';
    if (value.startsWith('http:') && !value.startsWith('http://')) {
      value = 'http://${value.substring(5)}';
    }
    if (value.startsWith('https:') && !value.startsWith('https://')) {
      value = 'https://${value.substring(6)}';
    }
    if (!value.contains('://') && value.contains('.')) return 'https://$value';
    return value;
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
