import 'dart:convert';

import '../core/tvbox_crypto.dart';
import '../models/cms_source.dart';

/// 一次解析的结果：可直接入库的接口源 + 需要再拉一层的 TVBox 订阅地址。
class SourceBundle {
  const SourceBundle({
    this.sources = const <CmsSource>[],
    this.subscriptionUrls = const <String>[],
  });

  final List<CmsSource> sources;

  /// TVBox 配置里 `urls` 字段里指向其它配置文件（或 txt 订阅）的地址。
  final List<String> subscriptionUrls;

  bool get isEmpty => sources.isEmpty && subscriptionUrls.isEmpty;
}

/// TVBox 配置解析。
///
/// 兼容的写法：
/// - `{"sites":[{"key":"x","name":"A站","type":1,"api":"csp_AppYsV2","ext":"https://a.com/api.php/provide/vod/"}]}`
/// - `{"sites":[{"name":"B站","api":"https://b.com/api.php/provide/vod/"}]}`
/// - `{"urls":[{"url":"https://x.com/config.json","name":"合集"}]}`（需要再拉一层）
/// - `{"api":"https://c.com/api.php/provide/vod/"}`
/// - TVBox 加密配置：`$#key#$` + AES-128-CBC 密文 + 13 字节 IV（十六进制文本）
///
/// 大部分站点标着 `type:3`（spider，需要 jar / drpy），但真实采集接口常常藏在
/// `ext`（对象 / JSON 字符串 / 数组）里，这种情况按 `ext` 里的接口导入。
SourceBundle parseSourceBundle(String text) {
  var trimmed = text.trim();
  if (trimmed.isEmpty) return const SourceBundle();

  // TVBox 加密配置（`$#key#$` + AES-128-CBC 密文 + 13 字节 IV）：先解出明文 JSON
  final decrypted = TvBoxCrypto.decode(trimmed);
  if (decrypted != null) trimmed = decrypted.trim();

  dynamic decoded;
  try {
    decoded = jsonDecode(trimmed);
  } catch (_) {
    return SourceBundle(sources: _parsePlainText(trimmed));
  }

  if (decoded is List) {
    return SourceBundle(sources: _parseJsonList(decoded));
  }
  if (decoded is! Map) return const SourceBundle();

  final sources = <CmsSource>[];
  final urls = <String>[];

  void collectUrls(String key) {
    final value = decoded[key];
    if (value is! List) return;
    for (final item in value) {
      if (item is String) {
        if (item.startsWith('http')) urls.add(item);
      } else if (item is Map) {
        final raw = (item['url'] ?? item['api'] ?? item['ext'] ?? '').toString().trim();
        if (raw.startsWith('http')) urls.add(raw);
      }
    }
  }

  for (final key in const ['urls', 'subs', 'subscriptions']) {
    collectUrls(key);
  }

  for (final key in const ['sites', 'list', 'data', 'sources']) {
    final value = decoded[key];
    if (value is! List) continue;
    sources.addAll(_parseJsonList(value));
  }

  // 单条配置：顶层直接给了接口地址
  if (sources.isEmpty) {
    final direct = _sourceFromMap(Map<String, dynamic>.from(decoded));
    if (direct != null) sources.add(direct);
  }

  return SourceBundle(
    sources: _dedupe(sources),
    subscriptionUrls: urls.toSet().toList(growable: false),
  );
}

/// 只想要接口源时的便捷入口。
List<CmsSource> parseTvBoxConfig(String text) => parseSourceBundle(text).sources;

List<CmsSource> _parseJsonList(List<dynamic> raw) {
  final result = <CmsSource>[];
  for (final item in raw) {
    if (item is! Map) {
      if (item is String && item.trim().startsWith('http')) {
        final api = item.trim();
        result.add(CmsSource(
          id: CmsSource.newSourceId() + '_${result.length}',
          name: Uri.tryParse(api)?.host ?? '未命名源',
          api: api,
        ));
      }
      continue;
    }
    final source = _sourceFromMap(Map<String, dynamic>.from(item));
    if (source != null) result.add(source);
  }
  return result;
}

/// 把一条 TVBox site / 订阅条目换算成苹果CMS接口地址；无法直接播放的返回 null。
///
/// TVBox 的 `type` 3/4 是 spider（需要 jar / drpy 插件，影枢跑不了），但大量配置
/// 把**真实的 maccms 采集接口**放在 `ext` 里，这种照样能导入。
CmsSource? _sourceFromMap(Map<String, dynamic> json) {
  final type = json['type'];
  // 0 = XML 接口，本应用只支持 JSON 版苹果CMS接口
  if (type is int && type == 0) return null;

  final apiRaw = (json['api'] ?? json['apiUrl'] ?? json['api_url'] ?? '').toString().trim();
  final urlRaw = (json['url'] ?? '').toString().trim();

  String? api;
  for (final candidate in [apiRaw, urlRaw]) {
    if (_isUsableApi(candidate)) {
      api = candidate.trim();
      break;
    }
  }
  if (api == null) {
    final extUrl = _extUrl(json['ext']);
    if (extUrl != null && _looksLikeMaccmsApi(extUrl)) api = extUrl;
  }
  if (api == null) return null;
  if (_looksLikeConfig(api)) return null;

  final rawName = (json['name'] ?? json['title'] ?? json['key'] ?? '').toString().trim();
  final name = rawName.isEmpty ? (Uri.tryParse(api)?.host ?? '未命名源') : rawName;
  return CmsSource(
    id: CmsSource.newSourceId(),
    name: name,
    api: api,
  );
}

/// 看起来就是一个能直接用的采集接口：http 地址，且不是脚本 / 配置 / 多域名列表。
bool _isUsableApi(String value) {
  final url = value.trim();
  if (!url.startsWith('http://') && !url.startsWith('https://')) return false;
  if (url.contains(',') || url.contains(' ')) return false;
  return !_looksLikeAsset(url);
}

/// 从 TVBox 的 `ext` 里挖接口地址（对象 / JSON 字符串 / 数组 / 纯地址都认）。
String? _extUrl(dynamic ext) {
  if (ext == null) return null;
  if (ext is Map) {
    for (final key in const ['url', 'api', 'extend', 'siteUrl', 'site', 'baseUrl', 'base_url']) {
      final value = ext[key];
      if (value is String && value.trim().startsWith('http')) return value.trim();
    }
    for (final value in ext.values) {
      final nested = _extUrl(value);
      if (nested != null) return nested;
    }
    return null;
  }
  if (ext is List) {
    for (final item in ext) {
      final nested = _extUrl(item);
      if (nested != null) return nested;
    }
    return null;
  }
  final text = ext.toString().trim();
  if (text.isEmpty) return null;
  if (text.startsWith('http')) return text;
  if (!text.startsWith('{') && !text.startsWith('[')) {
    // 配置作者偶尔把 JSON 写坏，这里宽松匹配一下里面的地址
    final match = RegExp(
      r'''["']?(?:url|api|extend|siteUrl)["']?\s*[:=]\s*["']([^"']+)["']''',
      caseSensitive: false,
    ).firstMatch(text);
    final found = match?.group(1);
    return (found != null && found.startsWith('http')) ? found : null;
  }
  try {
    return _extUrl(jsonDecode(text));
  } catch (_) {
    return null;
  }
}

/// 是否像 maccms 采集接口（`api.php/provide/vod`、`api.php/v1.vod`、`inc/api_mac10_all.php`…）。
///
/// 用来过滤 spider 源 `ext` 里的干扰项：drpy 脚本、配置文件、多域名列表都不是接口。
bool _looksLikeMaccmsApi(String url) {
  if (!_isUsableApi(url)) return false;
  final lower = url.toLowerCase();
  return lower.contains('api') || lower.contains('.php') || lower.contains('provide/vod');
}

/// 明显是资源文件而不是接口：`.json / .txt / .js / .mjs / .yml`。
bool _looksLikeAsset(String url) {
  final lower = url.toLowerCase();
  return RegExp(r'\.(?:json|txt|js|mjs|ya?ml)(?:[?#]|$)').hasMatch(lower);
}

bool _looksLikeConfig(String url) {
  final lower = url.toLowerCase();
  return lower.endsWith('.json') || lower.endsWith('.txt') || lower.endsWith('.yml');
}

/// 纯文本订阅：每行 `名称,接口` / `名称 接口` / 仅接口。
List<CmsSource> _parsePlainText(String text) {
  final sources = <CmsSource>[];
  for (final rawLine in text.split(RegExp(r'\r?\n'))) {
    final line = rawLine.trim();
    if (line.isEmpty || line.startsWith('#')) continue;

    var name = '';
    var api = '';
    final sepIndex = line.indexOf(RegExp(r'[,，\s]'));
    if (sepIndex > 0 && !line.startsWith('http')) {
      name = line.substring(0, sepIndex).trim();
      api = line.substring(sepIndex + 1).trim();
    } else {
      api = line;
    }
    api = api.replaceAll(RegExp(r'^\s*[-|]+\s*'), '').trim();
    if (!api.startsWith('http')) continue;
    if (name.isEmpty) name = Uri.tryParse(api)?.host ?? '未命名源';
    sources.add(CmsSource(
      id: CmsSource.newSourceId() + '_${sources.length}',
      name: name,
      api: api,
    ));
  }
  return sources;
}

List<CmsSource> _dedupe(List<CmsSource> input) {
  final seen = <String>{};
  final result = <CmsSource>[];
  for (final source in input) {
    if (!source.api.startsWith('http')) continue;
    final key = source.api.replaceAll(RegExp(r'/+$'), '');
    if (seen.add(key)) result.add(source);
  }
  return result;
}

/// 判断订阅内容为什么解析不了，给出能看懂的提示；能正常解析时返回 null。
String? describeUnsupportedBody(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return '订阅内容为空';

  // 加密配置写过但一条源都没剩下：说明解密没问题，是内容里没有能直接播的接口
  if (TvBoxCrypto.decode(trimmed) != null) {
    return '这是 TVBox 加密配置，影枢已经解开了，但里面都是需要插件引擎的 spider 源，'
        '没有可直接播放的苹果CMS接口';
  }

  final lower = trimmed.toLowerCase();
  if (lower.startsWith('<!doctype') ||
      lower.startsWith('<html') ||
      lower.contains('<body') ||
      lower.contains('<head')) {
    return '这个地址返回的是网页（HTML），不是配置文件。'
        'TVBox 的订阅链接一般要具体到配置路径（如 /xxx.json），根目录多半只是站点首页';
  }

  if (RegExp(r'^\$#[^#]*#\$').hasMatch(trimmed)) {
    return '这段内容是 TVBox 加密配置，但用通用算法解不开（可能换了密钥或换了加密方式）';
  }

  final compact = trimmed.replaceAll(RegExp(r'\s'), '');
  if (compact.length >= 256 &&
      compact.length.isEven &&
      RegExp(r'^[0-9a-fA-F]+$').hasMatch(compact)) {
    return '这段内容全是十六进制字符，但没有 TVBox 加密头部标记（\$#key#\$），'
        '不是常见的加密配置';
  }

  if (lower.startsWith('%pdf')) return '这是 PDF 文件，不是订阅配置';
  return null;
}

