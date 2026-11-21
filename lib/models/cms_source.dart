/// 一条苹果CMS v10 采集接口订阅源。
class CmsSource {
  const CmsSource({
    required this.id,
    required this.name,
    required this.api,
    this.enabled = true,
    this.note = '',
  });

  final String id;
  final String name;

  /// 采集接口完整地址，如 https://host/api.php/provide/vod/
  final String api;
  final bool enabled;
  final String note;

  String get host {
    final uri = Uri.tryParse(api);
    if (uri == null || uri.host.isEmpty) return api;
    return uri.host;
  }

  CmsSource copyWith({String? name, String? api, bool? enabled, String? note}) {
    return CmsSource(
      id: id,
      name: name ?? this.name,
      api: api ?? this.api,
      enabled: enabled ?? this.enabled,
      note: note ?? this.note,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'api': api,
        'enabled': enabled,
        'note': note,
      };

  factory CmsSource.fromJson(Map<String, dynamic> json, {String? fallbackId}) {
    final rawApi = (json['api'] ?? json['url'] ?? json['apiUrl'] ?? json['api_url'] ?? '')
        .toString()
        .trim();
    final fallbackName = Uri.tryParse(rawApi)?.host ?? '未命名源';
    return CmsSource(
      id: (json['id'] ?? fallbackId ?? newSourceId()).toString(),
      name: (json['name'] ?? json['title'] ?? fallbackName).toString().trim(),
      api: rawApi,
      enabled: json['enabled'] is bool ? json['enabled'] as bool : true,
      note: (json['note'] ?? json['desc'] ?? '').toString(),
    );
  }

  static String newSourceId() => 'src_${DateTime.now().microsecondsSinceEpoch}';
}
