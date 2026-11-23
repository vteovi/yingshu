const String kAppName = '影枢';
const String kAppNameEn = 'CineHub';
const String kAppVersion = '0.12.9';
const String kAppPackage = 'com.yingshu.player';

/// 部分苹果CMS站点会校验 UA，默认伪装成桌面浏览器。
const String kDefaultUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

/// 内置 UA 预设：可以一键填入，也可以再手动改。
class UaPreset {
  const UaPreset(this.label, this.value, {this.note = ''});

  final String label;
  final String value;
  final String note;
}

const List<UaPreset> kUserAgentPresets = [
  UaPreset('默认浏览器', kDefaultUserAgent, note: '桌面 Chrome，兼容性最好'),
  UaPreset('TVBox（okhttp 3.12）', 'okhttp/3.12.11', note: 'TVBox 客户端默认值，多数源适配'),
  UaPreset('TVBox 新版（okhttp 4.12）', 'okhttp/4.12.0', note: '新打包的 TVBox 分支常用'),
  UaPreset('手机 Chrome',
      'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36',
      note: '手机端页面口径，部分站点按移动端返回不同结果'),
  UaPreset('Android TV 盒子',
      'Mozilla/5.0 (Linux; Android 9; SHIELD Android TV) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
      note: '电视盒子端，适合大屏源'),
  UaPreset('iPhone Safari',
      'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) '
          'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 '
          'Mobile/15E148 Safari/604.1',
      note: 'iOS 端'),
  UaPreset('VLC（LibVLC）', 'LibVLC/3.0.20 (Linux; Android 13)', note: '个别播放类接口专用'),
];

/// 播放器拉流时使用的 UA：直接用手机浏览器口径。
///
/// 与接口请求的 UA 分开：不少片源 CDN 只对浏览器 UA 放行 m3u8，
/// 而采集接口反而认 okhttp / TVBox 的写法。
const String kPlayerUserAgent =
    'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36';

/// 采集接口常用后缀，供添加源时的输入提示。
const String kApiHint = 'https://your-domain.com/api.php/provide/vod/';
