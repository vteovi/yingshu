import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// 固定端口：只在局域网里用，方便输入时只填 IP。
const int kLanSyncPort = 47820;

/// 同步数据包：订阅源、收藏、历史、设置。
class LanSyncData {
  const LanSyncData({
    required this.sources,
    required this.favorites,
    required this.history,
    this.settings = const {},
  });

  final List<Map<String, dynamic>> sources;
  final List<Map<String, dynamic>> favorites;
  final List<Map<String, dynamic>> history;

  /// 应用设置（主题、海报样式、播放方向等），只在对方改过才补过来。
  final Map<String, dynamic> settings;

  static const LanSyncData empty =
      LanSyncData(sources: [], favorites: [], history: []);

  Map<String, dynamic> toJson() => {
        'app': 'yingshu',
        'kind': 'lan-sync',
        'version': 1,
        'sources': sources,
        'favorites': favorites,
        'history': history,
        'settings': settings,
      };

  factory LanSyncData.fromJson(Map<String, dynamic> json) {
    List<Map<String, dynamic>> listOf(Object? raw) {
      if (raw is! List) return const [];
      return raw
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList(growable: false);
    }

    return LanSyncData(
      sources: listOf(json['sources']),
      favorites: listOf(json['favorites']),
      history: listOf(json['history']),
      settings: json['settings'] is Map
          ? Map<String, dynamic>.from(json['settings'] as Map)
          : const {},
    );
  }
}

/// 合并结果：各自新增了多少条。
class SyncMergeResult {
  const SyncMergeResult({
    this.sources = 0,
    this.favorites = 0,
    this.history = 0,
    this.historyUpdated = 0,
    this.settings = 0,
  });

  final int sources;
  final int favorites;
  final int history;
  final int historyUpdated;

  /// 补过来的设置项数量（本机还是默认值的那些）。
  final int settings;

  int get total => sources + favorites + history + settings;

  String get summary =>
      '新增 $sources 个源 · $favorites 条收藏 · $history 条历史'
      '${historyUpdated > 0 ? ' · 更新 $historyUpdated 条播放进度' : ''}'
      '${settings > 0 ? ' · 补齐 $settings 项设置' : ''}';

  Map<String, dynamic> toJson() => {
        'sources': sources,
        'favorites': favorites,
        'history': history,
        'historyUpdated': historyUpdated,
        'settings': settings,
      };

  factory SyncMergeResult.fromJson(Map<String, dynamic> json) => SyncMergeResult(
        sources: (json['sources'] as num?)?.toInt() ?? 0,
        favorites: (json['favorites'] as num?)?.toInt() ?? 0,
        history: (json['history'] as num?)?.toInt() ?? 0,
        historyUpdated: (json['historyUpdated'] as num?)?.toInt() ?? 0,
        settings: (json['settings'] as num?)?.toInt() ?? 0,
      );
}

/// 本机在局域网里的 IPv4 地址（优先私有网段）。
Future<String?> lanSyncLocalAddress() async {
  try {
    final interfaces =
        await NetworkInterface.list(type: InternetAddressType.IPv4, includeLoopback: false);
    final all = <String>[];
    for (final interface in interfaces) {
      for (final address in interface.addresses) {
        if (address.address.isNotEmpty) all.add(address.address);
      }
    }
    for (final address in all) {
      if (address.startsWith('192.168.') ||
          address.startsWith('10.') ||
          address.startsWith('172.')) {
        return address;
      }
    }
    return all.isEmpty ? null : all.first;
  } catch (_) {
    return null;
  }
}

/// 主机端：开一个局域网 HTTP 服务，等另一台设备来取数据、再把自己的数据推回来。
class LanSyncHost {
  LanSyncHost._(this._server, this.address, this.code);

  final HttpServer _server;
  final String address;
  final String code;

  /// 收到对端数据后要做的事（通常是合并），由页面注入。
  Future<SyncMergeResult> Function(LanSyncData data)? onReceive;

  /// 对方已经推过数据了，用这个认一次完成。
  final Completer<SyncMergeResult> received = Completer<SyncMergeResult>();

  int get port => _server.port;

  static Future<LanSyncHost> start({
    required LanSyncData Function() snapshot,
    Future<SyncMergeResult> Function(LanSyncData data)? onReceive,
  }) async {
    HttpServer server;
    try {
      server = await HttpServer.bind(InternetAddress.anyIPv4, kLanSyncPort);
    } on SocketException {
      // 端口被占了就随机挑一个，页面会把完整地址显示出来
      server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    }
    final ip = await lanSyncLocalAddress();
    final host = LanSyncHost._(
      server,
      '${ip ?? '0.0.0.0'}:${server.port}',
      _newPairingCode(),
    );
    host.onReceive = onReceive;
    server.listen(
      (request) => host._handle(request, snapshot),
      onError: (_) {},
    );
    return host;
  }

  Future<void> stop() => _server.close(force: true);

  Future<void> _handle(HttpRequest request, LanSyncData Function() snapshot) async {
    final response = request.response;
    response.headers.contentType = ContentType.json;
    try {
      if (request.uri.path != '/sync') {
        response.statusCode = HttpStatus.notFound;
        await response.close();
        return;
      }
      if ((request.headers.value('x-sync-code') ?? '') != code) {
        response.statusCode = HttpStatus.forbidden;
        response.write(jsonEncode({'error': '配对码不正确，请核对主机上显示的 6 位数字'}));
        await response.close();
        return;
      }
      if (request.method == 'GET') {
        response.write(jsonEncode(snapshot().toJson()));
      } else if (request.method == 'POST') {
        final body = await utf8.decoder.bind(request).join();
        final data = LanSyncData.fromJson(Map<String, dynamic>.from(jsonDecode(body) as Map));
        final merged = await (onReceive?.call(data) ?? Future.value(const SyncMergeResult()));
        response.write(jsonEncode({'ok': true, 'merge': merged.toJson()}));
        if (!received.isCompleted) received.complete(merged);
      } else {
        response.statusCode = HttpStatus.methodNotAllowed;
      }
    } catch (error) {
      response.statusCode = HttpStatus.internalServerError;
      response.write(jsonEncode({'error': '$error'}));
    }
    await response.close();
  }
}

/// 客户端：连上主机取数据，再把本机数据推过去。
class LanSyncClient {
  /// 把用户输入整理成 host:port 形式，只填 IP 时补默认端口。
  static String normalizeAddress(String input) {
    var value = input.trim();
    value = value.replaceFirst(RegExp(r'^https?://'), '');
    value = value.replaceAll(RegExp(r'/+$'), '');
    if (value.contains(':')) return value;
    return '$value:$kLanSyncPort';
  }

  static Future<LanSyncData> pull(String address, String code) async {
    final json = await _request('GET', address, code, null);
    return LanSyncData.fromJson(json);
  }

  static Future<SyncMergeResult> push(String address, String code, LanSyncData data) async {
    final json = await _request('POST', address, code, data.toJson());
    final merge = json['merge'];
    return SyncMergeResult.fromJson(
      merge is Map ? Map<String, dynamic>.from(merge) : const <String, dynamic>{},
    );
  }

  static Future<Map<String, dynamic>> _request(
    String method,
    String address,
    String code,
    Object? body,
  ) async {
    final uri = Uri.parse('http://${normalizeAddress(address)}/sync');
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
    try {
      final request = await client.openUrl(method, uri);
      request.headers.set('x-sync-code', code.trim());
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(body));
      }
      final response = await request.close().timeout(const Duration(seconds: 15));
      final text = await utf8.decoder.bind(response).join();
      Map<String, dynamic> json = const {};
      if (text.trim().isNotEmpty) {
        final decoded = jsonDecode(text);
        if (decoded is Map) json = Map<String, dynamic>.from(decoded);
      }
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException(json['error']?.toString() ?? 'HTTP ${response.statusCode}');
      }
      return json;
    } finally {
      client.close(force: true);
    }
  }
}

String _newPairingCode() {
  final random = Random.secure();
  return List.generate(6, (_) => random.nextInt(10)).join();
}
