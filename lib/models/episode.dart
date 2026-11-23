class Episode {
  const Episode({required this.name, required this.url});

  final String name;
  final String url;

  Map<String, dynamic> toJson() => {'name': name, 'url': url};
}

/// 一路播放源（同一部片子通常有 m3u8 / 直链等多路）。
class PlaySourceGroup {
  const PlaySourceGroup({required this.from, required this.episodes});

  final String from;
  final List<Episode> episodes;
}

/// 解析 vod_play_from / vod_play_url。
///
/// 线上数据格式：
/// play_from: `线路一$$$线路二`
/// play_url : `第1集$http://a.m3u8#第2集$http://b.m3u8$$$第1集$http://c.m3u8`
List<PlaySourceGroup> parsePlayGroups(String playFrom, String playUrl) {
  final groups = <PlaySourceGroup>[];
  if (playUrl.trim().isEmpty) return groups;

  final urlGroups = playUrl.split(r'$$$');
  final fromGroups = playFrom.split(r'$$$');

  for (var i = 0; i < urlGroups.length; i++) {
    final trimmedFrom = i < fromGroups.length ? fromGroups[i].trim() : '';
    final from = trimmedFrom.isEmpty ? '线路${i + 1}' : trimmedFrom;
    final episodes = <Episode>[];

    for (final segment in urlGroups[i].split('#')) {
      final text = segment.trim();
      if (text.isEmpty) continue;
      final sep = text.indexOf(r'$');
      if (sep <= 0) continue;
      final name = text.substring(0, sep).trim();
      final url = text.substring(sep + 1).trim();
      if (url.isEmpty) continue;
      episodes.add(Episode(
        name: name.isEmpty ? '第${episodes.length + 1}集' : name,
        url: url,
      ));
    }

    if (episodes.isNotEmpty) {
      groups.add(PlaySourceGroup(from: from, episodes: episodes));
    }
  }

  // 有些采集站第一路给的是网页播放页（`https://x.com/play/abcd`），
  // 第二路才是真正的 m3u8。默认线路优先取能直接播的那一路。
  final ranked = <PlaySourceGroup>[];
  final mediaGroups = <PlaySourceGroup>[];
  for (final group in groups) {
    final playable = group.episodes.isNotEmpty && _looksPlayable(group.episodes.first.url);
    if (playable) {
      mediaGroups.add(group);
    } else {
      ranked.add(group);
    }
  }
  return [...mediaGroups, ...ranked];
}

/// 粗判：地址看起来像视频流 / 直链（网页播放页不算，但播放器侧会再兜底解析）。
bool _looksPlayable(String url) {
  final lower = url.toLowerCase();
  return lower.contains('.m3u8') ||
      lower.contains('.mp4') ||
      lower.contains('.flv') ||
      lower.contains('.ts') ||
      lower.contains('.mkv') ||
      lower.contains('/index.m3u8');
}
