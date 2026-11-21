String _s(dynamic value) => value == null ? '' : value.toString();

/// 苹果CMS 返回的影视条目（列表与详情共用一套模型）。
class VodItem {
  const VodItem({
    required this.vodId,
    required this.name,
    this.pic = '',
    this.remarks = '',
    this.typeId = '',
    this.typeName = '',
    this.year = '',
    this.area = '',
    this.lang = '',
    this.actor = '',
    this.director = '',
    this.content = '',
    this.playFrom = '',
    this.playUrl = '',
    this.score = '',
    this.updatedAt = '',
  });

  final String vodId;
  final String name;
  final String pic;
  final String remarks;
  final String typeId;
  final String typeName;
  final String year;
  final String area;
  final String lang;
  final String actor;
  final String director;
  final String content;

  /// 播放源分组名，多个源以 $$$ 分隔
  final String playFrom;

  /// 剧集地址串，格式 集名$地址#集名$地址，多组以 $$$ 分隔
  final String playUrl;
  final String score;
  final String updatedAt;

  bool get hasPlayable => playUrl.trim().isNotEmpty;

  String get cleanContent {
    var text = content
        .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'<[^>]+>'), '')
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&quot;', '"');
    text = text.trim();
    return text;
  }

  /// 详情页副标题信息，用 · 拼接。
  String get metaLine {
    final parts = <String>[
      if (typeName.isNotEmpty) typeName,
      if (year.isNotEmpty) year,
      if (area.isNotEmpty) area,
      if (remarks.isNotEmpty) remarks,
    ];
    return parts.join(' · ');
  }

  factory VodItem.fromJson(Map<String, dynamic> json) {
    return VodItem(
      vodId: _s(json['vod_id']),
      name: _s(json['vod_name']).trim(),
      pic: _s(json['vod_pic']).trim(),
      remarks: _s(json['vod_remarks']).trim(),
      typeId: _s(json['type_id']),
      typeName: _s(json['type_name']).trim(),
      year: _s(json['vod_year']).trim(),
      area: _s(json['vod_area']).trim(),
      lang: _s(json['vod_lang']).trim(),
      actor: _s(json['vod_actor']).trim(),
      director: _s(json['vod_director']).trim(),
      content: _s(json['vod_content']).trim(),
      playFrom: _s(json['vod_play_from']).trim(),
      playUrl: _s(json['vod_play_url']).trim(),
      score: _s(json['vod_score']).trim(),
      updatedAt: _s(json['vod_time']).trim(),
    );
  }
}
