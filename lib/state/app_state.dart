import 'dart:async';

import 'package:flutter/material.dart';

import '../core/constants.dart';
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

  bool _checking = false;
  int _checkDone = 0;
  int _checkTotal = 0;

  String? _currentSourceId;
  String _userAgent = kDefaultUserAgent;
  bool _autoPlayNext = true;
  bool _rememberProgress = true;
  bool _skipIntroAd = true;
  ThemeMode _themeMode = ThemeMode.system;
  PosterSize _posterSize = PosterSize.medium;
  bool _landscapeCard = false;

  CmsApi get api => _api;
  String get userAgent => _userAgent;
  bool get autoPlayNext => _autoPlayNext;
  bool get rememberProgress => _rememberProgress;
  bool get skipIntroAd => _skipIntroAd;
  ThemeMode get themeMode => _themeMode;
  PosterSize get posterSize => _posterSize;
  bool get landscapeCard => _landscapeCard;

  List<CmsSource> get sources => List.unmodifiable(_sources);
  List<CmsSource> get enabledSources =>
      _sources.where((source) => source.enabled).toList(growable: false);
  List<FavoriteItem> get favorites => List.unmodifiable(_favorites);
  List<HistoryItem> get history => List.unmodifiable(_history);

  // ---------------------------------------------------------------- 检测状态
  bool get checking => _checking;
  int get checkDone => _checkDone;
  int get checkTotal => _checkTotal;
  double get checkProgress => _checkTotal == 0 ? 0 : _checkDone / _checkTotal;

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

    final settings = _store.readMap(LocalStore.keySettings);
    _userAgent = (settings['userAgent'] ?? '').toString().trim();
    if (_userAgent.isEmpty) _userAgent = kDefaultUserAgent;
    _autoPlayNext = settings['autoPlayNext'] is bool ? settings['autoPlayNext'] as bool : true;
    _rememberProgress =
        settings['rememberProgress'] is bool ? settings['rememberProgress'] as bool : true;
    _skipIntroAd = settings['skipIntroAd'] is bool ? settings['skipIntroAd'] as bool : true;
    _themeMode = _parseThemeMode(settings['themeMode']);
    _posterSize = PosterSize.parse(settings['posterSize']);
    _landscapeCard = settings['landscapeCard'] is bool ? settings['landscapeCard'] as bool : false;
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
    notifyListeners();

    // 限制并发，避免一次打几十个站点把网络和设备都拖住
    final queue = List<CmsSource>.from(targets);
    Future<void> worker() async {
      while (queue.isNotEmpty) {
        final source = queue.removeAt(0);
        final stopwatch = Stopwatch()..start();
        SourceHealth health;
        try {
          final index = await _api.probe(source.api);
          stopwatch.stop();
          final usable = index.categories.isNotEmpty || index.videos.isNotEmpty;
          health = SourceHealth(
            status: usable ? SourceHealthStatus.available : SourceHealthStatus.unavailable,
            message: usable
                ? '接口正常，${index.categories.length} 个分类 / ${index.videos.length} 条数据'
                : '接口有响应但没有返回分类或影片数据',
            latencyMs: stopwatch.elapsedMilliseconds,
            checkedAt: DateTime.now(),
          );
        } catch (error) {
          stopwatch.stop();
          health = SourceHealth(
            status: SourceHealthStatus.unavailable,
            message: error.toString().replaceFirst('CmsException: ', ''),
            latencyMs: stopwatch.elapsedMilliseconds,
            checkedAt: DateTime.now(),
          );
        }
        results[source.id] = health;
        _checkDone++;
        notifyListeners();
      }
    }

    final workerCount = targets.length < 4 ? targets.length : 4;
    await Future.wait(List<Future<void>>.generate(workerCount, (_) => worker()));

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

  Future<void> setLandscapeCard(bool value) async {
    if (_landscapeCard == value) return;
    _landscapeCard = value;
    await _persistSettings();
    notifyListeners();
  }

  Future<void> _persistSettings() {
    return _store.writeMap(LocalStore.keySettings, {
      'userAgent': _userAgent,
      'autoPlayNext': _autoPlayNext,
      'rememberProgress': _rememberProgress,
      'skipIntroAd': _skipIntroAd,
      'themeMode': _themeMode.name,
      'posterSize': _posterSize.key,
      'landscapeCard': _landscapeCard,
    });
  }
}
