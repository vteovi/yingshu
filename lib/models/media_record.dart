/// 收藏条目（只存轻量信息，重新进入详情页时再拉接口）。
class FavoriteItem {
  const FavoriteItem({
    required this.sourceId,
    required this.sourceName,
    required this.vodId,
    required this.name,
    this.pic = '',
    this.remarks = '',
    this.savedAt = 0,
  });

  final String sourceId;
  final String sourceName;
  final String vodId;
  final String name;
  final String pic;
  final String remarks;
  final int savedAt;

  Map<String, dynamic> toJson() => {
        'sourceId': sourceId,
        'sourceName': sourceName,
        'vodId': vodId,
        'name': name,
        'pic': pic,
        'remarks': remarks,
        'savedAt': savedAt,
      };

  factory FavoriteItem.fromJson(Map<String, dynamic> json) => FavoriteItem(
        sourceId: (json['sourceId'] ?? '').toString(),
        sourceName: (json['sourceName'] ?? '').toString(),
        vodId: (json['vodId'] ?? '').toString(),
        name: (json['name'] ?? '').toString(),
        pic: (json['pic'] ?? '').toString(),
        remarks: (json['remarks'] ?? '').toString(),
        savedAt: (json['savedAt'] as num?)?.toInt() ?? 0,
      );
}

/// 播放历史 / 断点续播。
class HistoryItem {
  const HistoryItem({
    required this.sourceId,
    required this.sourceName,
    required this.vodId,
    required this.name,
    this.pic = '',
    this.groupName = '',
    this.episodeName = '',
    this.episodeUrl = '',
    this.episodeIndex = 0,
    this.positionMs = 0,
    this.durationMs = 0,
    this.updatedAt = 0,
  });

  final String sourceId;
  final String sourceName;
  final String vodId;
  final String name;
  final String pic;
  final String groupName;
  final String episodeName;
  final String episodeUrl;
  final int episodeIndex;
  final int positionMs;
  final int durationMs;
  final int updatedAt;

  double get progress {
    if (durationMs <= 0) return 0;
    return (positionMs / durationMs).clamp(0.0, 1.0);
  }

  Duration get position => Duration(milliseconds: positionMs);

  Map<String, dynamic> toJson() => {
        'sourceId': sourceId,
        'sourceName': sourceName,
        'vodId': vodId,
        'name': name,
        'pic': pic,
        'groupName': groupName,
        'episodeName': episodeName,
        'episodeUrl': episodeUrl,
        'episodeIndex': episodeIndex,
        'positionMs': positionMs,
        'durationMs': durationMs,
        'updatedAt': updatedAt,
      };

  factory HistoryItem.fromJson(Map<String, dynamic> json) => HistoryItem(
        sourceId: (json['sourceId'] ?? '').toString(),
        sourceName: (json['sourceName'] ?? '').toString(),
        vodId: (json['vodId'] ?? '').toString(),
        name: (json['name'] ?? '').toString(),
        pic: (json['pic'] ?? '').toString(),
        groupName: (json['groupName'] ?? '').toString(),
        episodeName: (json['episodeName'] ?? '').toString(),
        episodeUrl: (json['episodeUrl'] ?? '').toString(),
        episodeIndex: (json['episodeIndex'] as num?)?.toInt() ?? 0,
        positionMs: (json['positionMs'] as num?)?.toInt() ?? 0,
        durationMs: (json['durationMs'] as num?)?.toInt() ?? 0,
        updatedAt: (json['updatedAt'] as num?)?.toInt() ?? 0,
      );

  HistoryItem copyWith({
    String? groupName,
    String? episodeName,
    String? episodeUrl,
    int? episodeIndex,
    int? positionMs,
    int? durationMs,
    int? updatedAt,
  }) {
    return HistoryItem(
      sourceId: sourceId,
      sourceName: sourceName,
      vodId: vodId,
      name: name,
      pic: pic,
      groupName: groupName ?? this.groupName,
      episodeName: episodeName ?? this.episodeName,
      episodeUrl: episodeUrl ?? this.episodeUrl,
      episodeIndex: episodeIndex ?? this.episodeIndex,
      positionMs: positionMs ?? this.positionMs,
      durationMs: durationMs ?? this.durationMs,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}
