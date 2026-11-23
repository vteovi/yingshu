/// 海报图处理：苹果 CMS 的 `vod_pic` 常见三种脏数据 + 图片站防盗链。
///
/// 1. 协议相对地址（`//img.host/a.jpg`）在 Flutter 里直接报错，补成 https。
/// 2. 相对路径（`/upload/a.jpg`）补成源站绝对地址。
/// 3. 图片站常校验 Referer，缺了就返回 403，所以统一带上源站 Referer 与浏览器 UA。
library;

const String _kImageUserAgent =
    'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) '
    'Chrome/120.0.0.0 Mobile Safari/537.36';

String _originOf(String? api) {
  if (api == null || api.isEmpty) return '';
  final uri = Uri.tryParse(api);
  if (uri == null || uri.host.isEmpty) return '';
  return '${uri.scheme.isEmpty ? 'https' : uri.scheme}://${uri.host}';
}

/// 把各种写法的海报地址整理成可以直接请求的绝对 URL。
String normalizeImageUrl(String raw, {String? api}) {
  final url = raw.trim();
  if (url.isEmpty) return '';
  if (url.startsWith('//')) return 'https:$url';
  if (url.startsWith('http://') || url.startsWith('https://')) return url;
  final origin = _originOf(api);
  if (origin.isEmpty) return url;
  if (url.startsWith('/')) return '$origin$url';
  return '$origin/$url';
}

/// 图片请求头：Referer 取订阅源站点，避免图片站防盗链返回 403。
Map<String, String> imageHeadersFor(String? api) {
  final origin = _originOf(api);
  return {
    'User-Agent': _kImageUserAgent,
    if (origin.isNotEmpty) 'Referer': '$origin/',
  };
}
