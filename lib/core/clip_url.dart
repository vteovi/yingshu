/// 剪贴板里捞地址用的公共逻辑。
///
/// 「新建订阅源」「从订阅链接导入」两个入口都要自动粘贴剪贴板里的接口地址，
/// 判定规则放一处，改一次两边都跟着变。
library;

/// 从一段文本里挑出第一个「像接口地址」的片段。
///
/// 常见剪贴板内容是「看看这个 https://xx.com/api.php/provide/vod/ 挺快」这种
/// 夹在聊天里的句子，所以按空白切分逐个试，而不是整段当地址。
/// 裸域名（`xx.com/api.php/provide/vod/`）会补成 `https://`。
String? findUrlInText(String? raw) {
  final text = (raw ?? '').trim();
  if (text.isEmpty) return null;
  for (final token in text.split(RegExp(r'\s+'))) {
    var value = token.trim();
    if (value.length < 10) continue;
    if (!value.startsWith('http://') && !value.startsWith('https://')) {
      if (value.contains('://') || !value.contains('.')) continue;
      value = 'https://$value';
    }
    final uri = Uri.tryParse(value);
    if (uri == null || uri.host.isEmpty || !uri.host.contains('.')) continue;
    return value;
  }
  return null;
}
