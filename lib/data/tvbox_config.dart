import 'dart:convert';

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
SourceBundle parseSourceBundle(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return const SourceBundle();

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
CmsSource? _sourceFromMap(Map<String, dynamic> json) {
  final type = json['type'];
  // 0 = XML，4/5 = 需要 TVBox 内置解析器，本应用都接不了
  if (type is int && (type == 0 || type == 4 || type == 5)) return null;

  final apiRaw = (json['api'] ?? json['apiUrl'] ?? json['api_url'] ?? '').toString().trim();
  final extRaw = (json['ext'] ?? '').toString().trim();
  final urlRaw = (json['url'] ?? '').toString().trim();

  String? api;
  if (apiRaw.startsWith('http')) {
    api = apiRaw;
  } else if (urlRaw.startsWith('http') && !_looksLikeConfig(urlRaw)) {
    api = urlRaw;
  } else {
    api = _resolveExt(extRaw);
  }
  if (api == null && extRaw.startsWith('http')) api = extRaw;
  if (api == null) return null;

  // TVBox 的配置地址（.json / .txt）不是接口，交给上层继续拉取
  if (_looksLikeConfig(api)) return null;

  final rawName = (json['name'] ?? json['title'] ?? json['key'] ?? '').toString().trim();
  final name = rawName.isEmpty ? (Uri.tryParse(api)?.host ?? '未命名源') : rawName;
  return CmsSource(
    id: CmsSource.newSourceId(),
    name: name,
    api: api,
  );
}

/// ext 可能是 JSON 字符串：{"url":"https://...","ext":...}
String? _resolveExt(String ext) {
  if (ext.startsWith('http')) return ext;
  if (!ext.startsWith('{')) return null;
  try {
    final decoded = jsonDecode(ext);
    if (decoded is Map) {
      for (final key in const ['url', 'api', 'ext', 'site', 'baseUrl', 'base_url']) {
        final value = decoded[key];
        if (value is String && value.trim().startsWith('http')) return value.trim();
      }
    }
  } catch (_) {}
  return null;
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
