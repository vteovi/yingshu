import 'dart:convert';

import 'package:dio/dio.dart';

import '../core/constants.dart';
import '../models/cms_source.dart';
import '../models/vod.dart';

String _s(dynamic value) => value == null ? '' : value.toString();

class CmsException implements Exception {
  CmsException(this.message);

  final String message;

  @override
  String toString() => message;
}

class CmsCategory {
  const CmsCategory({required this.typeId, required this.typeName});

  final String typeId;
  final String typeName;
}

class CmsIndex {
  const CmsIndex({required this.categories, required this.videos});

  final List<CmsCategory> categories;
  final List<VodItem> videos;
}

class VodPage {
  const VodPage({
    required this.videos,
    this.page = 1,
    this.pageCount = 1,
    this.total = 0,
  });

  final List<VodItem> videos;
  final int page;
  final int pageCount;
  final int total;

  bool get hasMore => page < pageCount;
}

class SearchHit {
  const SearchHit({required this.source, required this.vod});

  final CmsSource source;
  final VodItem vod;
}

/// 苹果CMS v10 采集接口客户端。
///
/// 约定参数：
/// - `ac=list`        分类 + 最近更新
/// - `ac=detail&t=`   按分类取列表（分页）
/// - `ac=detail&wd=`  关键词搜索
/// - `ac=detail&ids=` 详情（带播放地址）
class CmsApi {
  CmsApi()
      : _dio = Dio(BaseOptions(
          connectTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(seconds: 20),
          sendTimeout: const Duration(seconds: 10),
          followRedirects: true,
          maxRedirects: 4,
        ));

  final Dio _dio;
  String _userAgent = kDefaultUserAgent;

  String get userAgent => _userAgent;

  set userAgent(String value) {
    _userAgent = value.trim().isEmpty ? kDefaultUserAgent : value.trim();
  }

  Future<CmsIndex> fetchIndex(CmsSource source) => probe(source.api);

  Future<CmsIndex> probe(String apiUrl) async {
    final map = await _request(apiUrl, {'ac': 'list'});
    final categories = <CmsCategory>[];
    final rawClass = map['class'];
    if (rawClass is List) {
      for (final item in rawClass) {
        if (item is Map) {
          final id = _s(item['type_id']);
          final name = _s(item['type_name']);
          if (id.isEmpty && name.isEmpty) continue;
          categories.add(CmsCategory(typeId: id, typeName: name));
        }
      }
    }
    final videos = _parseList(map['list']);
    return CmsIndex(
      categories: categories,
      videos: await _fillMissingPics(apiUrl, videos),
    );
  }

  Future<VodPage> fetchList(
    CmsSource source, {
    required String typeId,
    int page = 1,
  }) async {
    final map = await _request(source.api, {
      'ac': 'detail',
      if (typeId.isNotEmpty) 't': typeId,
      'pg': page,
    });
    final pageResult = _pageOf(map);
    final videos = await _fillMissingPics(source.api, pageResult.videos);
    return VodPage(
      videos: videos,
      page: pageResult.page,
      pageCount: pageResult.pageCount,
      total: pageResult.total,
    );
  }

  /// 有些接口的 `ac=list` 不返回 `vod_pic`（例如 jyzyapi），首页就会一片空白。
  /// 这种情况补一次批量详情（`ac=detail&ids=1,2,3`）把海报填回来。
  Future<List<VodItem>> _fillMissingPics(String apiUrl, List<VodItem> videos) async {
    if (videos.isEmpty) return videos;
    final missing = videos.where((v) => v.pic.trim().isEmpty).toList(growable: false);
    if (missing.isEmpty || missing.length < videos.length) return videos;
    final ids = missing.map((v) => v.vodId).where((id) => id.isNotEmpty).take(30).toList();
    if (ids.isEmpty) return videos;

    Map<String, dynamic> map;
    try {
      map = await _request(apiUrl, {'ac': 'detail', 'ids': ids.join(',')});
    } catch (_) {
      return videos;
    }
    final detailed = _parseList(map['list']);
    if (detailed.isEmpty) return videos;
    final pics = <String, String>{};
    for (final item in detailed) {
      if (item.pic.trim().isNotEmpty) pics[item.vodId] = item.pic;
    }
    if (pics.isEmpty) return videos;
    return videos
        .map((v) => pics.containsKey(v.vodId) ? v.copyWith(pic: pics[v.vodId]!) : v)
        .toList(growable: false);
  }

  Future<VodPage> search(CmsSource source, String keyword, {int page = 1}) async {
    final keywordTrimmed = keyword.trim();
    if (keywordTrimmed.isEmpty) {
      return const VodPage(videos: []);
    }
    Map<String, dynamic> map;
    try {
      map = await _request(source.api, {'ac': 'detail', 'wd': keywordTrimmed, 'pg': page});
    } on CmsException {
      map = await _request(source.api, {'ac': 'videolist', 'wd': keywordTrimmed, 'pg': page});
    }
    final result = _pageOf(map);
    if (result.videos.isEmpty) {
      // 少数站点只支持 videolist 搜索。
      try {
        final fallback = await _request(
          source.api,
          {'ac': 'videolist', 'wd': keywordTrimmed, 'pg': page},
        );
        return _pageOf(fallback);
      } on CmsException {
        return result;
      }
    }
    return result;
  }

  Future<VodItem?> fetchDetail(CmsSource source, String vodId) async {
    final map = await _request(source.api, {'ac': 'detail', 'ids': vodId});
    final list = _parseList(map['list']);
    if (list.isEmpty) return null;
    return list.first;
  }

  /// 并发搜索所有启用的源，单个源失败不影响整体结果。
  Future<List<SearchHit>> searchAll(
    List<CmsSource> sources,
    String keyword, {
    int page = 1,
  }) async {
    final keywordTrimmed = keyword.trim();
    if (keywordTrimmed.isEmpty || sources.isEmpty) return const [];

    final results = await Future.wait(sources.map((source) async {
      try {
        final pageResult = await search(source, keywordTrimmed, page: page);
        return pageResult.videos
            .map((vod) => SearchHit(source: source, vod: vod))
            .toList(growable: false);
      } catch (_) {
        return const <SearchHit>[];
      }
    }));

    final hits = <SearchHit>[];
    for (final list in results) {
      hits.addAll(list);
    }
    return hits;
  }

  Future<Map<String, dynamic>> _request(
    String apiUrl,
    Map<String, dynamic> params,
  ) async {
    final uri = Uri.tryParse(apiUrl.trim());
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      throw CmsException('接口地址不合法：$apiUrl');
    }

    Response<String> response;
    try {
      response = await _dio.get<String>(
        uri.toString(),
        queryParameters: params,
        options: Options(
          responseType: ResponseType.plain,
          headers: {
            'User-Agent': _userAgent,
            'Accept': 'application/json, text/plain, */*',
          },
          validateStatus: (status) => status != null && status < 500,
        ),
      );
    } on DioException catch (e) {
      throw CmsException('网络请求失败：${_friendlyDioError(e)}');
    }

    final status = response.statusCode ?? 0;
    if (status >= 400) {
      throw CmsException('接口返回 HTTP $status');
    }

    final body = response.data ?? '';
    final map = _decodeObject(body);
    if (map == null) {
      throw CmsException('接口返回内容不是有效 JSON，可能不是苹果CMS采集接口');
    }

    final code = _s(map['code']);
    if (code.isNotEmpty && code != '1') {
      final msg = _s(map['msg']);
      throw CmsException(msg.isEmpty ? '接口返回异常（code=$code）' : msg);
    }
    return map;
  }

  String _friendlyDioError(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return '连接超时，检查网络或接口地址';
      case DioExceptionType.transformTimeout:
        return '响应解析超时，接口返回内容可能过大';
      case DioExceptionType.badCertificate:
        return '证书校验失败';
      case DioExceptionType.connectionError:
        return '无法连接到服务器';
      case DioExceptionType.badResponse:
        return '服务器响应异常';
      case DioExceptionType.cancel:
        return '请求已取消';
      case DioExceptionType.unknown:
        return e.message ?? '未知错误';
    }
  }

  Map<String, dynamic>? _decodeObject(String body) {
    var text = body.trim();
    if (text.isEmpty) return null;
    if (text.codeUnitAt(0) == 0xFEFF) text = text.substring(1);
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {
      // 有些站点在 JSON 前后附带 HTML 或 BOM，退化为截取首个对象。
    }
    final start = text.indexOf('{');
    final end = text.lastIndexOf('}');
    if (start >= 0 && end > start) {
      try {
        final decoded = jsonDecode(text.substring(start, end + 1));
        if (decoded is Map) return Map<String, dynamic>.from(decoded);
      } catch (_) {}
    }
    return null;
  }

  VodPage _pageOf(Map<String, dynamic> map) {
    return VodPage(
      videos: _parseList(map['list']),
      page: int.tryParse(_s(map['page'])) ?? 1,
      pageCount: int.tryParse(_s(map['pagecount'])) ?? 1,
      total: int.tryParse(_s(map['total'])) ?? 0,
    );
  }

  List<VodItem> _parseList(dynamic raw) {
    if (raw is! List) return const [];
    final items = <VodItem>[];
    for (final item in raw) {
      if (item is Map) {
        final vod = VodItem.fromJson(Map<String, dynamic>.from(item));
        if (vod.name.isNotEmpty) items.add(vod);
      }
    }
    return items;
  }
}
