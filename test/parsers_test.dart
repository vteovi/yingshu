import 'package:yingshu/data/subscription.dart';
import 'package:yingshu/models/episode.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parsePlayGroups', () {
    test('多线路 + 多集的苹果CMS播放串', () {
      final groups = parsePlayGroups(
        '线路一\$\$\$线路二',
        '第1集\$https://a.com/1.m3u8#第2集\$https://a.com/2.m3u8'
            '\$\$\$第1集\$https://b.com/1.m3u8',
      );

      expect(groups.length, 2);
      expect(groups[0].from, '线路一');
      expect(groups[0].episodes.length, 2);
      expect(groups[0].episodes[1].name, '第2集');
      expect(groups[0].episodes[1].url, 'https://a.com/2.m3u8');
      expect(groups[1].from, '线路二');
      expect(groups[1].episodes.single.url, 'https://b.com/1.m3u8');
    });

    test('空的播放地址直接返回空列表', () {
      expect(parsePlayGroups('', ''), isEmpty);
      expect(parsePlayGroups('线路一', ''), isEmpty);
    });

    test('缺少线路名时自动命名为线路N', () {
      final groups = parsePlayGroups('', '正片\$https://a.com/x.mp4');
      expect(groups.single.from, '线路1');
    });
  });

  group('parseSubscriptionText', () {
    test('每行 名称,地址 的纯文本', () {
      final sources = parseSubscriptionText(
        '站点A,https://a.com/api.php/provide/vod/\n'
        'https://b.com/api.php/provide/vod/',
      );
      expect(sources.length, 2);
      expect(sources.first.name, '站点A');
      expect(sources.first.api, 'https://a.com/api.php/provide/vod/');
      expect(sources.last.name, 'b.com');
    });

    test('JSON 数组', () {
      final sources = parseSubscriptionText(
        '[{"name":"A站","api":"https://a.com/api.php/provide/vod/"}]',
      );
      expect(sources.single.name, 'A站');
      expect(sources.single.api, 'https://a.com/api.php/provide/vod/');
    });

    test('带 sites 外壳的 JSON', () {
      final sources = parseSubscriptionText(
        '{"sites":[{"title":"B站","url":"https://b.com/api.php/provide/vod/"}]}',
      );
      expect(sources.single.name, 'B站');
    });

    test('无效内容返回空', () {
      expect(parseSubscriptionText('随便写点什么'), isEmpty);
      expect(parseSubscriptionText(''), isEmpty);
    });
  });
}
