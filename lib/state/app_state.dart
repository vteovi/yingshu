import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../core/constants.dart';
import '../core/lan_sync.dart';
import '../data/cms_api.dart';
import '../data/local_store.dart';
import '../data/subscription.dart';
import '../data/tvbox_config.dart';
import '../models/cms_source.dart';
import '../models/media_record.dart';
import '../models/source_health.dart';
import '../models/vod.dart';

/// 一次订阅源检测的汇总结果。
class SourceCheckSummary {
  const SourceCheckSummary({
    required this.available,
    required this.unavailable,
    required this.total,
  });

  final int available;
  final int unavailable;
  final int total;
}

/// 海报大小：决定网格里一行放几张。
///
/// 列数不是写死的，而是按「可用宽度 ÷ 每张的目标宽度」算，
/// 所以手机竖屏是 3/2/1 列，平板大屏会自动变成更多列。
enum PosterSize {
  small('small', '小'),
  medium('medium', '中'),
  large('large', '大');

  const PosterSize(this.key, this.label);

  final String key;
  final String label;

  static PosterSize parse(Object? raw) {
    final value = raw?.toString();
    for (final item in values) {
      if (item.key == value) return item;
    }
    return PosterSize.medium;
  }
}

/// 海报排布方式：
/// - [grid]：规整网格，海报统一按 2:3 裁切，行列对齐；
/// - [actual]：按海报图实际宽高比排（瀑布流），不再统一裁切，长短不一。
enum PosterLayout {
  grid('grid', '规整'),
  actual('actual', '原始比例');

  const PosterLayout(this.key, this.label);

  final String key;
  final String label;

  static PosterLayout parse(Object? raw) {
    final value = raw?.toString();
    for (final item in values) {
      if (item.key == value) return item;
    }
    return PosterLayout.grid;
  }
}

/// 海报样式：竖向 / 横向 / 原始比例（设置页里是三选一的分段按钮）。
///
/// 此前是「海报排布（规整/原始比例）」+「横向卡片开关」两个独立设置，
/// 组合起来有互相冲突的情况（原始比例 + 横向卡片），所以合成一个三档选项。
enum PosterMode {
  portrait('portrait', '竖向'),
  landscape('landscape', '横向'),
  actual('actual', '原始比例');

  const PosterMode(this.key, this.label);

  final String key;
  final String label;

  static PosterMode parse(Object? raw) {
    final value = raw?.toString();
    for (final item in values) {
      if (item.key == value) return item;
    }
    return PosterMode.portrait;
  }
}

/// 播放页屏幕方向：决定进入播放页后要不要、以及按什么规则转屏。
enum PlayerOrientation {
  auto('auto', '自动旋转', '忽略系统旋转锁，横着拿就横屏、竖着拿就竖屏'),
  system('system', '跟随系统', '播放页不干预方向，由系统当前的方向设置决定'),
  video('video', '跟随视频', '按片源宽高比定死方向：宽屏转横屏，竖屏视频保持竖屏');

  const PlayerOrientation(this.key, this.label, this.description);

  final String key;
  final String label;
  final String description;

  static PlayerOrientation parse(Object? raw) {
    final value = raw?.toString();
    for (final item in values) {
      if (item.key == value) return item;
    }
    return PlayerOrientation.video;
  }
}

/// 全局状态：订阅源、收藏、历史、设置。
class AppState extends ChangeNotifier {
  AppState(this._store);

  final LocalStore _store;
  final CmsApi _api = CmsApi();
  final SubscriptionFetcher _fetcher = SubscriptionFetcher();

  final List<CmsSource> _sources = [];
  final Map<String, SourceHealth> _health = {};
  final List<FavoriteItem> _favorites = [];
  final List<HistoryItem> _history = [];

  /// 搜索记录：最近搜过的关键词，新的在前，最多 20 条。
  final List<String> _searchHistory = [];

  bool _checking = false;
  int _checkDone = 0;
  int _checkTotal = 0;

  /// 正在被探测的源 id：列表里这些行实时显示「检测中」。
  final Set<String> _checkingIds = <String>{};

  String? _currentSourceId;
  String _userAgent = kDefaultUserAgent;
  bool _autoPlayNext = true;
  bool _rememberProgress = true;
  bool _skipIntroAd = false;
  ThemeMode _themeMode = ThemeMode.system;
  PosterSize _posterSize = PosterSize.medium;
  PosterMode _posterMode = PosterMode.portrait;
  PlayerOrientation _playerOrientation = PlayerOrientation.video;

  CmsApi get api => _api;
  String get userAgent => _userAgent;
  bool get autoPlayNext => _autoPlayNext;
  bool get rememberProgress => _rememberProgress;
  bool get skipIntroAd => _skipIntroAd;
  ThemeMode get themeMode => _themeMode;
  PosterSize get posterSize => _posterSize;
  PosterMode get posterMode => _posterMode;
  PlayerOrientation get playerOrientation => _playerOrientation;

  /// 兼容旧调用：横向卡片 = 海报样式选了「横向」
  bool get landscapeCard => _posterMode == PosterMode.landscape;

  /// 兼容旧调用：排布方式由海报样式推导，「原始比例」才走瀑布流
  PosterLayout get posterLayout =>
      _posterMode == PosterMode.actual ? PosterLayout.actual : PosterLayout.grid;

  /// 真正生效的横版卡片：只有竖向/横向两档是网格，原始比例走瀑布流
  bool get useLandscapeCard => _posterMode == PosterMode.landscape;

  List<CmsSource> get sources => List.unmodifiable(_sources);
  List<CmsSource> get enabledSources =>
      _sources.where((source) => source.enabled).toList(growable: false);
  List<FavoriteItem> get favorites => List.unmodifiable(_favorites);
  List<HistoryItem> get history => List.unmodifiable(_history);
  List<String> get searchHistory => List.unmodifiable(_searchHistory);

  /// 读上一次启动缓存下来的首页数据（同步、纯本地，几十毫秒内就能拿到）。
  CmsIndex? cachedIndex(String sourceId) {
    final raw = _store.readString(LocalStore.indexCacheKey(sourceId));
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        final index = CmsIndex.fromJson(Map<String, dynamic>.from(decoded));
        if (index.categories.isEmpty && index.videos.isEmpty) return null;
        return index;
      }
    } catch (_) {}
    return null;
  }

  /// 网络刷新成功后回写首页缓存，下次冷启动直接用它出图。
  Future<void> saveIndex(String sourceId, CmsIndex index) {
    return _store.writeString(
      LocalStore.indexCacheKey(sourceId),
      jsonEncode(index.toJson()),
    );
  }

  // ---------------------------------------------------------------- 检测状态
  bool get checking => _checking;
  int get checkDone => _checkDone;
  int get checkTotal => _checkTotal;
  double get checkProgress => _checkTotal == 0 ? 0 : _checkDone / _checkTotal;

  /// 这个源此刻正在探测中（列表行显示 spinner）。
  bool isCheckingSource(String sourceId) => _checkingIds.contains(sourceId);

  SourceHealth healthOf(String sourceId) =>
      _health[sourceId] ?? const SourceHealth();

  int get availableCount => _sources.where((s) => healthOf(s.id).isAvailable).length;
  int get unavailableCount => _sources.where((s) => healthOf(s.id).isUnavailable).length;

  CmsSource? get currentSource {
    final byId = _sources.where((s) => s.id == _currentSourceId && s.enabled);
    if (byId.isNotEmpty) return byId.first;
    final firstEnabled = _sources.where((s) => s.enabled);
    return firstEnabled.isEmpty ? null : firstEnabled.first;
  }

  CmsSource? findSource(String? id) {
    if (id == null) return null;
    for (final source in _sources) {
      if (source.id == id) return source;
    }
    return null;
  }

  Future<void> init() async {
    for (final map in _store.readList(LocalStore.keySources)) {
      final source = CmsSource.fromJson(map);
      if (source.api.startsWith('http') && source.api.isNotEmpty) {
        _sources.add(source);
      }
    }

    _currentSourceId = _store.readString(LocalStore.keyCurrentSource);

    for (final map in _store.readList(LocalStore.keyFavorites)) {
      _favorites.add(FavoriteItem.fromJson(map));
    }

    for (final map in _store.readList(LocalStore.keyHistory)) {
      _history.add(HistoryItem.fromJson(map));
    }
    _history.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

    for (final map in _store.readList(LocalStore.keySearchHistory)) {
      final keyword = (map['keyword'] ?? '').toString().trim();
      if (keyword.isNotEmpty && !_searchHistory.contains(keyword)) {
        _searchHistory.add(keyword);
      }
    }

    final settings = _store.readMap(LocalStore.keySettings);
    _userAgent = (settings['userAgent'] ?? '').toString().trim();
    if (_userAgent.isEmpty) _userAgent = kDefaultUserAgent;
    _autoPlayNext = settings['autoPlayNext'] is bool ? settings['autoPlayNext'] as bool : true;
    _rememberProgress =
        settings['rememberProgress'] is bool ? settings['rememberProgress'] as bool : true;
    // 跳过片头广告默认关闭：识错广告段会误跳正片，要用户自己开
    _skipIntroAd = settings['skipIntroAd'] is bool ? settings['skipIntroAd'] as bool : false;
    _themeMode = _parseThemeMode(settings['themeMode']);
    _posterSize = PosterSize.parse(settings['posterSize']);
    _playerOrientation = PlayerOrientation.parse(settings['playerOrientation']);
    // 新设置只有 posterMode 一个键；老版本存档里是
    // posterLayout(规整/原始比例) + landscapeCard(开关)，这里做一次迁移
    if (settings.containsKey('posterMode')) {
      _posterMode = PosterMode.parse(settings['posterMode']);
    } else if (PosterLayout.parse(settings['posterLayout']) == PosterLayout.actual) {
      _posterMode = PosterMode.actual;
    } else if (settings['landscapeCard'] is bool && settings['landscapeCard'] as bool) {
      _posterMode = PosterMode.landscape;
    } else {
      _posterMode = PosterMode.portrait;
    }
    _api.userAgent = _userAgent;
    _fetcher.userAgent = _userAgent;

    final rawHealth = settings['sourceHealth'];
    if (rawHealth is List) {
      for (final item in rawHealth.whereType<Map>()) {
        final map = Map<String, dynamic>.from(item);
        final id = (map['id'] ?? '').toString();
        if (id.isEmpty) continue;
        _health[id] = SourceHealth.fromJson(map);
      }
    }
    for (final map in _store.readList(LocalStore.keySourceHealth)) {
      final id = (map['id'] ?? '').toString();
      if (id.isEmpty) continue;
      _health[id] = SourceHealth.fromJson(map);
    }

    notifyListeners();
  }

  static ThemeMode _parseThemeMode(Object? raw) {
    switch (raw?.toString()) {
      case 'light':
        return ThemeMode.light;
      case 'dark':
        return ThemeMode.dark;
      case 'system':
        return ThemeMode.system;
      default:
        return ThemeMode.system;
    }
  }

  // ------------------------------------------------------------------ 订阅源

  Future<void> setCurrentSource(String id) async {
    if (_currentSourceId == id) return;
    _currentSourceId = id;
    await _store.writeString(LocalStore.keyCurrentSource, id);
    notifyListeners();
  }

  Future<void> addSource(CmsSource source) async {
    if (_sources.any((s) => s.api == source.api)) {
      throw CmsException('该接口已存在');
    }
    _sources.add(source);
    _currentSourceId ??= source.id;
    await _persistSources();
    notifyListeners();
  }

  Future<void> updateSource(CmsSource source) async {
    final index = _sources.indexWhere((s) => s.id == source.id);
    if (index < 0) return;
    _sources[index] = source;
    await _persistSources();
    notifyListeners();
  }

  Future<void> toggleSource(String id, bool enabled) async {
    final index = _sources.indexWhere((s) => s.id == id);
    if (index < 0) return;
    _sources[index] = _sources[index].copyWith(enabled: enabled);
    await _persistSources();
    notifyListeners();
  }

  Future<void> removeSource(String id) async {
    _sources.removeWhere((s) => s.id == id);
    if (_currentSourceId == id) _currentSourceId = null;
    final favoriteCount = _favorites.where((f) => f.sourceId == id).length;
    final historyCount = _history.where((h) => h.sourceId == id).length;
    _favorites.removeWhere((f) => f.sourceId == id);
    _history.removeWhere((h) => h.sourceId == id);
    _health.remove(id);
    await Future.wait([
      _persistSources(),
      _persistFavorites(),
      _persistHistory(),
      _persistHealth(),
    ]);
    _lastRemovedSourceCleanup = favoriteCount + historyCount;
    notifyListeners();
  }

  int _lastRemovedSourceCleanup = 0;
  int get lastRemovedSourceCleanup => _lastRemovedSourceCleanup;

  /// 批量导入订阅，按接口地址去重，返回新增数量。
  Future<int> importSources(List<CmsSource> incoming) async {
    var added = 0;
    for (final source in incoming) {
      final api = source.api.trim();
      if (api.isEmpty || !api.startsWith('http')) continue;
      if (_sources.any((s) => s.api == api)) continue;
      _sources.add(CmsSource(
        id: CmsSource.newSourceId() + '_$added',
        name: source.name.isEmpty ? (Uri.tryParse(api)?.host ?? '未命名源') : source.name,
        api: api,
        enabled: source.enabled,
        note: source.note,
      ));
      added++;
    }
    if (added > 0) {
      _currentSourceId ??= _sources.first.id;
      await _persistSources();
      notifyListeners();
    }
    return added;
  }

  Future<int> importFromUrl(String url) async {
    final list = await _fetcher.fetch(url);
    return importSources(list);
  }

  /// 导入粘贴内容 / 本地配置文件内容（支持 TVBox 配置与自有格式）。
  Future<int> importFromText(String text) async {
    return importSources(parseSourceBundle(text).sources);
  }

  Future<void> _persistSources() {
    return _store.writeList(
      LocalStore.keySources,
      _sources.map((s) => s.toJson()).toList(growable: false),
    );
  }

  Future<void> _persistHealth() {
    return _store.writeList(
      LocalStore.keySourceHealth,
      _health.entries
          .map((entry) => <String, dynamic>{'id': entry.key, ...entry.value.toJson()})
          .toList(growable: false),
    );
  }

  /// 探测单个源，返回检测结果（不落库，由调用方决定怎么用）。
  Future<SourceHealth> _probeSource(CmsSource source) async {
    final stopwatch = Stopwatch()..start();
    try {
      final index = await _api.probe(source.api);
      stopwatch.stop();
      final usable = index.categories.isNotEmpty || index.videos.isNotEmpty;
      return SourceHealth(
        status: usable ? SourceHealthStatus.available : SourceHealthStatus.unavailable,
        message: usable
            ? '接口正常，${index.categories.length} 个分类 / ${index.videos.length} 条数据'
            : '接口有响应但没有返回分类或影片数据',
        latencyMs: stopwatch.elapsedMilliseconds,
        checkedAt: DateTime.now(),
      );
    } catch (error) {
      stopwatch.stop();
      return SourceHealth(
        status: SourceHealthStatus.unavailable,
        message: error.toString().replaceFirst('CmsException: ', ''),
        latencyMs: stopwatch.elapsedMilliseconds,
        checkedAt: DateTime.now(),
      );
    }
  }

  /// 单个检测：只刷新这一个源的状态，不改排序、也不动它的启用开关。
  ///
  /// 批量检测会顺带把可用源启用、不可用源关闭并重排；单个检测只想知道
  /// 「这一个现在还能不能用」，所以这里刻意保持克制。
  Future<SourceHealth?> checkSource(String sourceId) async {
    final source = findSource(sourceId);
    if (source == null) return null;
    if (_checkingIds.contains(sourceId)) return healthOf(sourceId);
    _checkingIds.add(sourceId);
    notifyListeners();
    final health = await _probeSource(source);
    _health[sourceId] = health;
    _checkingIds.remove(sourceId);
    await _persistHealth();
    notifyListeners();
    return health;
  }

  /// 逐个探测订阅源是否可用，测完把可用的打开并排到前面、不可用的关掉排到后面。
  Future<SourceCheckSummary> checkSources() async {
    if (_checking || _sources.isEmpty) {
      return SourceCheckSummary(
        available: availableCount,
        unavailable: unavailableCount,
        total: _sources.length,
      );
    }

    final targets = List<CmsSource>.from(_sources);
    final results = <String, SourceHealth>{};

    _checking = true;
    _checkDone = 0;
    _checkTotal = targets.length;
    _checkingIds.clear();
    notifyListeners();

    // 限制并发，避免一次打几十个站点把网络和设备都拖住
    final queue = List<CmsSource>.from(targets);
    Future<void> worker() async {
      while (queue.isNotEmpty) {
        final source = queue.removeAt(0);
        _checkingIds.add(source.id);
        notifyListeners();
        final health = await _probeSource(source);
        results[source.id] = health;
        // 每条结果一出来就落到界面上：卡片上的状态、进度条、计数都立刻更新
        _health[source.id] = health;
        _checkingIds.remove(source.id);
        _checkDone++;
        notifyListeners();
      }
    }

    final workerCount = targets.length < 4 ? targets.length : 4;
    await Future.wait(List<Future<void>>.generate(workerCount, (_) => worker()));
    _checkingIds.clear();

    // 可用的在前并打开，不可用的在后并关闭；同组内保持原有顺序
    final okList = targets
        .where((s) => results[s.id]?.isAvailable ?? false)
        .map((s) => s.copyWith(enabled: true))
        .toList();
    final badList = targets
        .where((s) => !(results[s.id]?.isAvailable ?? false))
        .map((s) => s.copyWith(enabled: false))
        .toList();
    _sources
      ..clear()
      ..addAll([...okList, ...badList]);

    _health
      ..removeWhere((id, _) => !targets.any((s) => s.id == id))
      ..addAll(results);

    if (_currentSourceId != null && badList.any((s) => s.id == _currentSourceId)) {
      _currentSourceId = okList.isEmpty ? null : okList.first.id;
      await _store.writeString(LocalStore.keyCurrentSource, _currentSourceId ?? '');
    }

    _checking = false;
    await Future.wait([_persistSources(), _persistHealth()]);
    notifyListeners();

    return SourceCheckSummary(
      available: okList.length,
      unavailable: badList.length,
      total: targets.length,
    );
  }

  // ------------------------------------------------------------------ 收藏

  bool isFavorite(String sourceId, String vodId) {
    return _favorites.any((f) => f.sourceId == sourceId && f.vodId == vodId);
  }

  Future<bool> toggleFavorite({required CmsSource source, required VodItem vod}) async {
    final existing = _favorites.indexWhere(
      (f) => f.sourceId == source.id && f.vodId == vod.vodId,
    );
    var nowFavorite = false;
    if (existing >= 0) {
      _favorites.removeAt(existing);
    } else {
      _favorites.insert(
        0,
        FavoriteItem(
          sourceId: source.id,
          sourceName: source.name,
          vodId: vod.vodId,
          name: vod.name,
          pic: vod.pic,
          remarks: vod.remarks,
          savedAt: DateTime.now().millisecondsSinceEpoch,
        ),
      );
      nowFavorite = true;
    }
    await _persistFavorites();
    notifyListeners();
    return nowFavorite;
  }

  Future<void> removeFavorite(FavoriteItem item) async {
    _favorites.removeWhere((f) => f.sourceId == item.sourceId && f.vodId == item.vodId);
    await _persistFavorites();
    notifyListeners();
  }

  Future<void> clearFavorites() async {
    _favorites.clear();
    await _persistFavorites();
    notifyListeners();
  }

  Future<void> _persistFavorites() {
    return _store.writeList(
      LocalStore.keyFavorites,
      _favorites.map((f) => f.toJson()).toList(growable: false),
    );
  }

  // ------------------------------------------------------------------ 历史

  HistoryItem? historyFor(String sourceId, String vodId) {
    for (final item in _history) {
      if (item.sourceId == sourceId && item.vodId == vodId) return item;
    }
    return null;
  }

  Future<void> saveProgress({
    required String sourceId,
    required String sourceName,
    required String vodId,
    required String vodName,
    required String vodPic,
    required String groupName,
    required String episodeName,
    required String episodeUrl,
    required int episodeIndex,
    required Duration position,
    required Duration duration,
  }) async {
    if (!_rememberProgress) return;
    if (position.inSeconds <= 0 && duration.inSeconds <= 0) return;

    final item = HistoryItem(
      sourceId: sourceId,
      sourceName: sourceName,
      vodId: vodId,
      name: vodName,
      pic: vodPic,
      groupName: groupName,
      episodeName: episodeName,
      episodeUrl: episodeUrl,
      episodeIndex: episodeIndex,
      positionMs: position.inMilliseconds,
      durationMs: duration.inMilliseconds,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    _history.removeWhere((h) => h.sourceId == sourceId && h.vodId == vodId);
    _history.insert(0, item);
    if (_history.length > 200) {
      _history.removeRange(200, _history.length);
    }
    await _persistHistory();
    notifyListeners();
  }

  Future<void> removeHistory(String sourceId, String vodId) async {
    _history.removeWhere((h) => h.sourceId == sourceId && h.vodId == vodId);
    await _persistHistory();
    notifyListeners();
  }

  Future<void> clearHistory() async {
    _history.clear();
    await _persistHistory();
    notifyListeners();
  }

  Future<void> _persistHistory() {
    return _store.writeList(
      LocalStore.keyHistory,
      _history.map((h) => h.toJson()).toList(growable: false),
    );
  }

  // ------------------------------------------------------------ 局域网同步

  /// 打包本机数据，给另一台设备取用。
  LanSyncData exportSyncData() => LanSyncData(
        sources: _sources.map((source) => source.toJson()).toList(growable: false),
        favorites: _favorites.map((item) => item.toJson()).toList(growable: false),
        history: _history.map((item) => item.toJson()).toList(growable: false),
        settings: {
          'themeMode': _themeMode.name,
          'posterSize': _posterSize.key,
          'posterMode': _posterMode.key,
          'playerOrientation': _playerOrientation.key,
          'autoPlayNext': _autoPlayNext,
          'rememberProgress': _rememberProgress,
          'skipIntroAd': _skipIntroAd,
        },
      );

  /// 源的身份标识：优先用接口地址，地址为空时退回名字。
  static String _syncSourceKey(String api, String name) {
    final normalized = api.trim().toLowerCase().replaceAll(RegExp(r'/+$'), '');
    return normalized.isEmpty ? 'name:${name.trim().toLowerCase()}' : normalized;
  }

  CmsSource? _findSourceBySyncKey(String key) {
    for (final source in _sources) {
      if (_syncSourceKey(source.api, source.name) == key) return source;
    }
    return null;
  }

  /// 合并另一台设备的数据：**只增不覆盖**。
  ///
  /// - 源：按接口地址去重，本机没有的才追加到末尾，同 id 冲突时换新 id；
  /// - 收藏 / 历史：先把对端的 sourceId 映射到本机对应源的 id，再按
  ///   （源, 影片）去重，重复的跳过；历史若对端进度更新则更新断点，
  ///   否则保留本机那条。
  Future<SyncMergeResult> mergeSyncData(LanSyncData data) async {
    final idMap = <String, String>{};
    var addedSources = 0;

    // ---- 1. 源
    for (final raw in data.sources) {
      final incoming = CmsSource.fromJson(raw);
      if (incoming.api.trim().isEmpty) continue;
      final key = _syncSourceKey(incoming.api, incoming.name);
      final existing = _findSourceBySyncKey(key);
      if (existing != null) {
        idMap[incoming.id] = existing.id;
        continue;
      }
      final existingIds = _sources.map((source) => source.id).toSet();
      final id = existingIds.contains(incoming.id) ? CmsSource.newSourceId() : incoming.id;
      _sources.add(CmsSource(
        id: id,
        name: incoming.name,
        api: incoming.api.trim(),
        enabled: incoming.enabled,
        note: incoming.note,
      ));
      idMap[incoming.id] = id;
      addedSources++;
    }

    String? localIdOf(String incomingSourceId) => idMap[incomingSourceId];

    // ---- 2. 收藏
    final favoriteKeys = <String>{
      for (final item in _favorites) '${item.sourceId}|${item.vodId}',
    };
    var addedFavorites = 0;
    for (final raw in data.favorites) {
      final incoming = FavoriteItem.fromJson(raw);
      final localId = localIdOf(incoming.sourceId);
      if (localId == null) continue; // 来源不在本机（对端那个源地址为空），跳过
      final key = '$localId|${incoming.vodId}';
      if (favoriteKeys.contains(key)) continue;
      final now = DateTime.now().millisecondsSinceEpoch;
      _favorites.add(FavoriteItem(
        sourceId: localId,
        sourceName: _sourceNameOf(localId, incoming.sourceName),
        vodId: incoming.vodId,
        name: incoming.name,
        pic: incoming.pic,
        remarks: incoming.remarks,
        savedAt: incoming.savedAt > 0 ? incoming.savedAt : now,
      ));
      favoriteKeys.add(key);
      addedFavorites++;
    }
    if (addedFavorites > 0) {
      _favorites.sort((a, b) => b.savedAt.compareTo(a.savedAt));
    }

    // ---- 3. 历史
    var addedHistory = 0;
    var updatedHistory = 0;
    for (final raw in data.history) {
      final incoming = HistoryItem.fromJson(raw);
      final localId = localIdOf(incoming.sourceId);
      if (localId == null) continue;
      final name = _sourceNameOf(localId, incoming.sourceName);
      final index = _history.indexWhere(
        (item) => item.sourceId == localId && item.vodId == incoming.vodId,
      );
      final remapped = _rekeyHistory(incoming, localId, name);
      if (index < 0) {
        _history.add(remapped);
        addedHistory++;
      } else if (incoming.updatedAt > _history[index].updatedAt) {
        // 同一集/同一影片：谁的进度更新就留谁的
        _history[index] = remapped;
        updatedHistory++;
      }
    }
    if (addedHistory > 0) {
      _history.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    }
    if (_history.length > 200) {
      _history.removeRange(200, _history.length);
    }

    // ---- 4. 设置：只补本机还是默认值的项，用户改过的一律不动
    var adoptedSettings = 0;
    final incomingSettings = data.settings;
    if (incomingSettings.isNotEmpty) {
      final theme = incomingSettings['themeMode']?.toString();
      if (_themeMode == ThemeMode.system && theme != null && theme != 'system') {
        final parsed = {'light': ThemeMode.light, 'dark': ThemeMode.dark}[theme];
        if (parsed != null) {
          _themeMode = parsed;
          adoptedSettings++;
        }
      }
      final size = PosterSize.parse(incomingSettings['posterSize']);
      if (_posterSize == PosterSize.medium && size != PosterSize.medium) {
        _posterSize = size;
        adoptedSettings++;
      }
      final mode = PosterMode.parse(incomingSettings['posterMode']);
      if (_posterMode == PosterMode.portrait && mode != PosterMode.portrait) {
        _posterMode = mode;
        adoptedSettings++;
      }
      final orientation = PlayerOrientation.parse(incomingSettings['playerOrientation']);
      if (_playerOrientation == PlayerOrientation.video &&
          orientation != PlayerOrientation.video) {
        _playerOrientation = orientation;
        adoptedSettings++;
      }
      if (incomingSettings['autoPlayNext'] is bool &&
          _autoPlayNext &&
          incomingSettings['autoPlayNext'] as bool == false) {
        _autoPlayNext = false;
        adoptedSettings++;
      }
      if (incomingSettings['rememberProgress'] is bool &&
          _rememberProgress &&
          incomingSettings['rememberProgress'] as bool == false) {
        _rememberProgress = false;
        adoptedSettings++;
      }
      if (incomingSettings['skipIntroAd'] is bool &&
          !_skipIntroAd &&
          incomingSettings['skipIntroAd'] as bool == true) {
        _skipIntroAd = true;
        adoptedSettings++;
      }
    }

    if (addedSources > 0 ||
        addedFavorites > 0 ||
        addedHistory > 0 ||
        updatedHistory > 0 ||
        adoptedSettings > 0) {
      await Future.wait([
        _persistSources(),
        _persistFavorites(),
        _persistHistory(),
        if (adoptedSettings > 0) _persistSettings(),
      ]);
      notifyListeners();
    }

    return SyncMergeResult(
      sources: addedSources,
      favorites: addedFavorites,
      history: addedHistory,
      historyUpdated: updatedHistory,
      settings: adoptedSettings,
    );
  }

  String _sourceNameOf(String sourceId, String fallback) {
    for (final source in _sources) {
      if (source.id == sourceId) return source.name;
    }
    return fallback;
  }

  HistoryItem _rekeyHistory(HistoryItem item, String sourceId, String sourceName) {
    return HistoryItem(
      sourceId: sourceId,
      sourceName: sourceName,
      vodId: item.vodId,
      name: item.name,
      pic: item.pic,
      groupName: item.groupName,
      episodeName: item.episodeName,
      episodeUrl: item.episodeUrl,
      episodeIndex: item.episodeIndex,
      positionMs: item.positionMs,
      durationMs: item.durationMs,
      updatedAt: item.updatedAt,
    );
  }

  // ------------------------------------------------------------------ 设置

  Future<void> setUserAgent(String value) async {
    _userAgent = value.trim().isEmpty ? kDefaultUserAgent : value.trim();
    _api.userAgent = _userAgent;
    _fetcher.userAgent = _userAgent;
    await _persistSettings();
    notifyListeners();
  }

  Future<void> setAutoPlayNext(bool value) async {
    _autoPlayNext = value;
    await _persistSettings();
    notifyListeners();
  }

  Future<void> setRememberProgress(bool value) async {
    _rememberProgress = value;
    await _persistSettings();
    notifyListeners();
  }

  Future<void> setSkipIntroAd(bool value) async {
    _skipIntroAd = value;
    await _persistSettings();
    notifyListeners();
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    if (_themeMode == mode) return;
    _themeMode = mode;
    await _persistSettings();
    notifyListeners();
  }

  Future<void> setPosterSize(PosterSize size) async {
    if (_posterSize == size) return;
    _posterSize = size;
    await _persistSettings();
    notifyListeners();
  }

  Future<void> setPosterMode(PosterMode mode) async {
    if (_posterMode == mode) return;
    _posterMode = mode;
    await _persistSettings();
    notifyListeners();
  }

  Future<void> setPlayerOrientation(PlayerOrientation mode) async {
    if (_playerOrientation == mode) return;
    _playerOrientation = mode;
    await _persistSettings();
    notifyListeners();
  }

  // ---------------------------------------------------------------- 搜索记录
  Future<void> addSearchHistory(String keyword) async {
    final value = keyword.trim();
    if (value.isEmpty) return;
    _searchHistory.removeWhere((item) => item.toLowerCase() == value.toLowerCase());
    _searchHistory.insert(0, value);
    if (_searchHistory.length > 20) {
      _searchHistory.removeRange(20, _searchHistory.length);
    }
    await _persistSearchHistory();
    notifyListeners();
  }

  Future<void> removeSearchHistory(String keyword) async {
    final before = _searchHistory.length;
    _searchHistory.removeWhere((item) => item == keyword);
    if (_searchHistory.length == before) return;
    await _persistSearchHistory();
    notifyListeners();
  }

  Future<void> clearSearchHistory() async {
    if (_searchHistory.isEmpty) return;
    _searchHistory.clear();
    await _persistSearchHistory();
    notifyListeners();
  }

  Future<void> _persistSearchHistory() {
    return _store.writeList(
      LocalStore.keySearchHistory,
      _searchHistory.map((keyword) => {'keyword': keyword}).toList(growable: false),
    );
  }

  Future<void> _persistSettings() {
    return _store.writeMap(LocalStore.keySettings, {
      'userAgent': _userAgent,
      'autoPlayNext': _autoPlayNext,
      'rememberProgress': _rememberProgress,
      'skipIntroAd': _skipIntroAd,
      'themeMode': _themeMode.name,
      'posterSize': _posterSize.key,
      'posterMode': _posterMode.key,
      'playerOrientation': _playerOrientation.key,
    });
  }
}
