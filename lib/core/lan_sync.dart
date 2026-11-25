import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// 共享端监听端口：局域网内固定，方便手动输入 IP 时只填地址。
const int kSyncHttpPort = 47820;

/// 局域网设备同步：零依赖，全部基于 dart:io。
///
/// 发现：UDP 组播 239.255.100.101:19529（TTL=1，只在本子网传播）。
///       共享端周期性广播，同步端监听组播收集设备，并支持手动输入 IP 兜底。
/// 传输：共享端在 47820 端口起 HttpServer，GET /sync 返回 JSON 原始数据。
///
/// 为什么不用 mDNS/NSD：Android 12+ 的 NsdManager 需要「附近设备」权限，
/// 原生 UDP 组播不需要任何额外权限，跨平台也省事。
class LanDevice {
  const LanDevice({required this.ip, required this.httpPort, required this.name});

  final String ip;
  final int httpPort;
  final String name;

  @override
  bool operator ==(Object other) =>
      other is LanDevice && other.ip == ip && other.httpPort == httpPort;

  @override
  int get hashCode => ip.hashCode ^ httpPort.hashCode;

  @override
  String toString() => '$name ($ip:$httpPort)';
}

/// 可同步的数据类别（顺序固定，影响 UI 与导出的键名）。
class SyncScope {
  const SyncScope(this.key, this.label);

  final String key;
  final String label;

  static const String sources = 'sources';
  static const String settings = 'settings';
  static const String favorites = 'favorites';
  static const String history = 'history';

  static const List<SyncScope> all = [
    SyncScope(sources, '订阅源'),
    SyncScope(settings, '设置'),
    SyncScope(favorites, '收藏'),
    SyncScope(history, '历史记录'),
  ];
}

class LanDiscovery {
  static const String _magic = 'YINGSHU-SYNC';
  static const String multicastGroup = '239.255.100.101';
  static const int discoveryPort = 19529;
  static const Duration _interval = Duration(seconds: 2);
  static const String _probePayload = '$_magic|PROBE';

  /// 本机用于局域网互通的 IPv4 地址。
  ///
  /// 直接取「第一个私有地址」可能拿到蜂窝、VPN、虚拟机网卡（10.16.x.x 之类），
  /// 跟真实路由器网段不符，所以优先挑像物理网卡（Wi-Fi/以太网）的接口。
  static Future<String?> getLocalIp() async {
    List<NetworkInterface> interfaces;
    try {
      interfaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );
    } catch (_) {
      return null;
    }
    String? fallback;
    for (final iface in interfaces) {
      for (final addr in iface.addresses) {
        final ip = addr.address;
        if (!_isPrivateIp(ip)) continue;
        fallback ??= ip;
        if (_looksLikePhysicalLan(iface)) return ip;
      }
    }
    return fallback;
  }

  static bool _looksLikePhysicalLan(NetworkInterface iface) {
    final name = iface.name.toLowerCase();
    const excluded = [
      'lo', 'loopback',
      'rmnet', 'ccmni', 'ppp', 'tun', 'tap', // 蜂窝 / VPN
      'vmnet', 'vmware', 'vbox', 'virtualbox', // 虚拟机
      'vethernet', 'hyper-v', 'hyperv', 'docker', 'br-', // 虚拟交换机 / 容器
      'bluetooth', 'bt', 'pan', // 蓝牙共享
      'zerotier', 'tailscale', 'wireguard', 'openvpn', // 隧道
    ];
    for (final item in excluded) {
      if (name.contains(item)) return false;
    }
    return true;
  }

  static bool _isPrivateIp(String ip) {
    if (ip.startsWith('192.168.')) return true;
    if (ip.startsWith('10.')) return true;
    if (ip.startsWith('172.')) {
      final part = int.tryParse(ip.split('.')[1]);
      if (part != null && part >= 16 && part <= 31) return true;
    }
    return false;
  }

  /// 共享端：周期广播自身，并监听探测包即时单播回应。返回停止函数。
  static Future<Future<void> Function()> startAnnouncing(int httpPort, String name) async {
    final sendSocket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    final payload = utf8.encode('$_magic|$httpPort|$name');
    final group = InternetAddress(multicastGroup);
    final recvSocket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      discoveryPort,
      reuseAddress: true,
    );
    try {
      recvSocket.joinMulticast(group);
    } catch (_) {
      // 部分 ROM/网络不支持组播：对方仍可手动输入 IP 连接
    }
    var stopped = false;
    void sendOnce({InternetAddress? to, int? toPort}) {
      if (stopped) return;
      try {
        if (to != null && toPort != null) {
          sendSocket.send(payload, to, toPort);
        } else {
          sendSocket.send(payload, group, discoveryPort);
        }
      } catch (_) {}
    }

    sendOnce();
    final timer = Timer.periodic(_interval, (_) => sendOnce());
    recvSocket.listen((event) {
      if (event != RawSocketEvent.read || stopped) return;
      final datagram = recvSocket.receive();
      if (datagram == null) return;
      final text = utf8.decode(datagram.data, allowMalformed: true);
      if (text == _probePayload) {
        sendOnce(to: datagram.address, toPort: datagram.port);
      }
    });
    return () async {
      if (stopped) return;
      stopped = true;
      timer.cancel();
      try {
        recvSocket.leaveMulticast(group);
      } catch (_) {}
      recvSocket.close();
      sendSocket.close();
    };
  }

  /// 同步端：监听组播，发现局域网内正在共享的设备。
  static Future<LanListener> startListening(void Function(LanDevice) onDevice) async {
    final socket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      discoveryPort,
      reuseAddress: true,
    );
    try {
      socket.joinMulticast(InternetAddress(multicastGroup));
    } catch (_) {}
    final localIp = await getLocalIp();
    void handle(Datagram? datagram) {
      if (datagram == null) return;
      final fromIp = datagram.address.address;
      if (fromIp == localIp) return; // 忽略自身
      final text = utf8.decode(datagram.data, allowMalformed: true);
      if (!text.startsWith(_magic)) return;
      final parts = text.split('|');
      if (parts.length < 3) return;
      final port = int.tryParse(parts[1]);
      if (port == null) return;
      onDevice(LanDevice(ip: fromIp, httpPort: port, name: parts[2]));
    }

    socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      handle(socket.receive());
    });
    return LanListener._(socket, () {
      try {
        socket.leaveMulticast(InternetAddress(multicastGroup));
      } catch (_) {}
      socket.close();
    });
  }
}

/// 监听句柄：支持被动发现与主动探测刷新。
class LanListener {
  LanListener._(this._socket, this._dispose);

  final RawDatagramSocket _socket;
  final void Function() _dispose;

  void probe() {
    try {
      _socket.send(
        utf8.encode(LanDiscovery._probePayload),
        InternetAddress(LanDiscovery.multicastGroup),
        LanDiscovery.discoveryPort,
      );
    } catch (_) {}
  }

  Future<void> stop() async => _dispose();
}

/// 同步数据包：订阅源、收藏、历史、设置。
class LanSyncData {
  const LanSyncData({
    this.sources = const [],
    this.favorites = const [],
    this.history = const [],
    this.settings = const {},
  });

  final List<Map<String, dynamic>> sources;
  final List<Map<String, dynamic>> favorites;
  final List<Map<String, dynamic>> history;
  final Map<String, dynamic> settings;

  static const LanSyncData empty = LanSyncData();

  /// 只留下指定类别，用于「选择要同步的数据」。
  LanSyncData filtered(Set<String> scopes) => LanSyncData(
        sources: scopes.contains(SyncScope.sources) ? sources : const [],
        favorites: scopes.contains(SyncScope.favorites) ? favorites : const [],
        history: scopes.contains(SyncScope.history) ? history : const [],
        settings: scopes.contains(SyncScope.settings) ? settings : const {},
      );

  Map<String, dynamic> toJson() => {
        'app': 'yingshu',
        'kind': 'lan-sync',
        'version': 2,
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

/// 合并结果：各类别新增了多少条。
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
  final int settings;

  int get total => sources + favorites + history + settings;

  int countOf(String scope) {
    switch (scope) {
      case SyncScope.sources:
        return sources;
      case SyncScope.settings:
        return settings;
      case SyncScope.favorites:
        return favorites;
      case SyncScope.history:
        return history;
    }
    return 0;
  }

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

/// 共享端 HTTP 服务：暴露选定类别的**实时**数据。
class SyncServer {
  SyncServer._(this._server);

  final HttpServer _server;

  int get port => _server.port;

  /// [load] 每次请求时调用，导出当前数据。
  /// 若把结果当参数传进来，那只是「点开启共享那一刻」的快照，
  /// 之后新加的收藏、刚看的记录都不会同步出去。
  static Future<SyncServer?> start(
    Future<LanSyncData> Function() load, {
    int port = kSyncHttpPort,
  }) async {
    HttpServer server;
    try {
      server = await HttpServer.bind(InternetAddress.anyIPv4, port);
    } on SocketException {
      try {
        server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
      } catch (_) {
        return null;
      }
    }
    server.idleTimeout = const Duration(seconds: 15);
    final instance = SyncServer._(server);
    server.listen((request) async {
      if (request.method != 'GET' || request.uri.path != '/sync') {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }
      try {
        final data = await load();
        final bytes = utf8.encode(jsonEncode({'ok': true, 'data': data.toJson()}));
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.json
          // 带上长度：对端能算进度，也能立刻知道总共多大
          ..contentLength = bytes.length
          ..add(bytes);
        await request.response.close();
      } catch (_) {
        request.response.statusCode = HttpStatus.internalServerError;
        await request.response.close();
      }
    });
    return instance;
  }

  Future<void> stop() => _server.close(force: true);
}

/// 同步过程中可预期的失败（已翻译成人话）。
class SyncException implements Exception {
  SyncException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 用户中途取消，单独成类，好和「失败」区分显示。
class SyncCancelled implements Exception {
  const SyncCancelled();

  @override
  String toString() => '已取消';
}

/// 同步端 HTTP 客户端。
class SyncClient {
  static const Duration connectTimeout = Duration(seconds: 10);

  /// 接收数据时的**空闲**超时：还有字节在来就不算超时。
  static const Duration idleTimeout = Duration(seconds: 20);

  static Future<LanSyncData> fetch(
    String host,
    int port, {
    void Function(int received)? onProgress,
    bool Function()? isCancelled,
  }) async {
    Object? lastError;
    for (var attempt = 0; attempt <= 1; attempt++) {
      try {
        return await _fetchOnce(host, port, onProgress, isCancelled);
      } catch (error) {
        lastError = error;
        if (attempt >= 1 || !_retryable(error)) break;
        await Future<void>.delayed(const Duration(milliseconds: 700));
      }
    }
    throw lastError!;
  }

  static Future<LanSyncData> _fetchOnce(
    String host,
    int port,
    void Function(int received)? onProgress,
    bool Function()? isCancelled,
  ) async {
    final client = HttpClient();
    try {
      client.connectionTimeout = connectTimeout;
      client.idleTimeout = idleTimeout;
      final uri = Uri.http('$host:$port', '/sync');
      final request = await client.getUrl(uri).timeout(connectTimeout);
      final response = await request.close().timeout(connectTimeout);
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        throw SyncException(
          '对方 $host:$port 返回 HTTP ${response.statusCode}，'
          '这个端口上跑的可能不是本应用',
        );
      }

      final total = response.contentLength;
      var received = 0;
      final bytes = BytesBuilder(copy: false);
      try {
        await for (final chunk in response.timeout(idleTimeout)) {
          bytes.add(chunk);
          received += chunk.length;
          onProgress?.call(received);
          if (isCancelled?.call() ?? false) throw const SyncCancelled();
        }
      } on TimeoutException {
        throw SyncException(
          total > 0
              ? '数据传到 ${_sizeText(received)} / ${_sizeText(total)} 就停住了。\n'
                  '· 对方是否刚息屏或被切到后台\n· 两台设备之间的 Wi-Fi 是否稳定'
              : '数据传到 ${_sizeText(received)} 就停住了。\n'
                  '· 对方是否刚息屏或被切到后台\n· 两台设备之间的 Wi-Fi 是否稳定',
        );
      }

      Object? decoded;
      try {
        decoded = jsonDecode(utf8.decode(bytes.takeBytes(), allowMalformed: true));
      } on FormatException {
        throw SyncException('对方返回的数据不是合法 JSON，可能传到一半被截断了');
      }
      if (decoded is! Map) throw SyncException('对方返回的数据格式不正确');
      final data = decoded['data'];
      if (data is! Map) throw SyncException('对方返回的数据缺少 data 字段');
      return LanSyncData.fromJson(Map<String, dynamic>.from(data));
    } finally {
      client.close(force: true);
    }
  }

  static String _sizeText(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  static bool _retryable(Object error) =>
      error is SocketException || error is TimeoutException || error is HttpException;

  /// 只测端口可达（连上即断），返回耗时毫秒。用于「测试连接」。
  static Future<int> ping(
    String host,
    int port, {
    Duration timeout = const Duration(seconds: 6),
  }) async {
    final stopwatch = Stopwatch()..start();
    final socket = await Socket.connect(host, port, timeout: timeout);
    final elapsed = stopwatch.elapsedMilliseconds;
    socket.destroy();
    return elapsed;
  }

  /// 把底层异常翻译成能照着排查的一句话。
  static String describeError(Object error, String host, int port) {
    final target = '$host:$port';
    if (error is SyncCancelled) return '已取消同步，本地数据没有改动。';
    if (error is SyncException) return error.message;
    if (error is TimeoutException) {
      return '连接 $target 超时：对方没有回应。\n'
          '· 对方是否还开着「开启共享」\n'
          '· 手机是否已息屏（息屏后系统会断开 Wi-Fi）\n'
          '· 两台设备是否连的同一个 Wi-Fi';
    }
    if (error is SocketException) {
      final message = error.message.toLowerCase();
      if (message.contains('timed out')) {
        return '连接 $target 超时：对方没有回应。\n'
            '· 对方是否还开着「开启共享」\n'
            '· 手机是否已息屏（息屏后系统会断开 Wi-Fi）\n'
            '· 两台设备是否连的同一个 Wi-Fi';
      }
      if (message.contains('refused')) {
        return '对方 $host 拒绝连接（$port 端口没有在监听）。\n'
            '多半是对方已经关掉了「开启共享」，或 App 被系统回收了。';
      }
      if (message.contains('unreachable') ||
          message.contains('host is down') ||
          message.contains('no route')) {
        return '网络到不了 $host。\n请确认对方 IP 没有变更、两台设备在同一 Wi-Fi。';
      }
      if (message.contains('failed host lookup')) {
        return '找不到地址 $host，请检查 IP 是否输错。';
      }
      return '网络错误：${error.message}（$target）';
    }
    return '$target 同步失败：$error';
  }
}
