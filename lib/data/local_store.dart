import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 轻量本地持久化：源列表、收藏、历史、设置都存成 JSON 字符串。
class LocalStore {
  LocalStore(this._prefs);

  final SharedPreferences _prefs;

  static const String keySources = 'cms_sources_v1';
  static const String keyFavorites = 'cms_favorites_v1';
  static const String keyHistory = 'cms_history_v1';
  static const String keySettings = 'cms_settings_v1';
  static const String keyCurrentSource = 'cms_current_source_v1';
  static const String keySourceHealth = 'cms_source_health_v1';
  static const String keySearchHistory = 'cms_search_history_v1';

  List<Map<String, dynamic>> readList(String key) {
    final raw = _prefs.getString(key);
    if (raw == null || raw.isEmpty) return const <Map<String, dynamic>>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return decoded
            .whereType<Map>()
            .map((item) => Map<String, dynamic>.from(item))
            .toList(growable: false);
      }
    } catch (_) {}
    return const [];
  }

  Future<void> writeList(String key, List<Map<String, dynamic>> value) {
    return _prefs.setString(key, jsonEncode(value));
  }

  Map<String, dynamic> readMap(String key) {
    final raw = _prefs.getString(key);
    if (raw == null || raw.isEmpty) return const <String, dynamic>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {}
    return const <String, dynamic>{};
  }

  Future<void> writeMap(String key, Map<String, dynamic> value) {
    return _prefs.setString(key, jsonEncode(value));
  }

  String? readString(String key) => _prefs.getString(key);

  Future<void> writeString(String key, String value) => _prefs.setString(key, value);

  Future<void> remove(String key) => _prefs.remove(key);
}
