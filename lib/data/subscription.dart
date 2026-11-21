import 'dart:convert';

import 'package:dio/dio.dart';

import '../models/cms_source.dart';

/// 订阅地址 / 订阅文本解析。
///
/// 支持三种写法：
/// 1. JSON 数组：[{"name":"站点A","api":"https://a.com/api.php/provide/vod/"}]
/// 2. 带外壳的 JSON：{"sites":[...]} 或 {"list":[...]} 或 {"data":[...]}
/// 3. 纯文本，每行一条：`站点名,接口地址` / `站点名 接口地址` / 仅接口地址
List<CmsSource> parseSubscriptionText(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return const [];

  final fromJson = _tryParseJson(trimmed);
  if (fromJson != null) return fromJson;

  final sources = <CmsSource>[];
  for (final rawLine in trimmed.split(RegExp(r'\r?\n'))) {
    final line = rawLine.trim();
    if (line.isEmpty || line.startsWith('#')) continue;

    String name = '';
    String api = '';

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

List<CmsSource>? _tryParseJson(String text) {
  dynamic decoded;
  try {
    decoded = jsonDecode(text);
  } catch (_) {
    return null;
  }

  List<dynamic>? rawList;
  if (decoded is List) {
    rawList = decoded;
  } else if (decoded is Map) {
    for (final key in const ['sites', 'list', 'data', 'sources', 'urls']) {
      final value = decoded[key];
      if (value is List) {
        rawList = value;
        break;
      }
    }
  }
  if (rawList == null) return null;

  final sources = <CmsSource>[];
  for (final item in rawList) {
    if (item is! Map) continue;
    final json = Map<String, dynamic>.from(item);
    if (json['api'] == null && json['url'] == null && json['apiUrl'] == null) continue;
    final source = CmsSource.fromJson(json);
    if (source.api.startsWith('http') && source.api.isNotEmpty) {
      sources.add(source);
    }
  }
  return sources;
}

/// 从远端订阅链接拉取源列表。
class SubscriptionFetcher {
  SubscriptionFetcher({Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 10),
              receiveTimeout: const Duration(seconds: 20),
            ));

  final Dio _dio;

  Future<List<CmsSource>> fetch(String url) async {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      throw Exception('订阅地址不合法');
    }
    final response = await _dio.get<String>(
      uri.toString(),
      options: Options(responseType: ResponseType.plain),
    );
    final body = response.data ?? '';
    final sources = parseSubscriptionText(body);
    if (sources.isEmpty) {
      throw Exception('未从订阅内容中解析到接口地址');
    }
    return sources;
  }
}
