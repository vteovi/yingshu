import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';

/// 把文本导出成文件：安卓走系统「另存为」(SAF)，桌面走 file_selector 的保存对话框。
class FileExport {
  FileExport._();

  static const MethodChannel _channel = MethodChannel('com.yingshu.player/files');

  /// 返回保存结果描述；用户取消时返回 null；失败时抛 [Exception]。
  static Future<String?> saveText({
    required String fileName,
    required String content,
    String mime = 'application/json',
  }) async {
    if (Platform.isAndroid) {
      try {
        final path = await _channel.invokeMethod<String>('exportText', {
          'fileName': fileName,
          'content': content,
          'mime': mime,
        });
        if (path == null) return null;
        return '已保存到你选择的目录';
      } on MissingPluginException {
        // 老版本 APK 没有这个通道，退回到下面的桌面逻辑
      } on PlatformException catch (error) {
        throw Exception(error.message ?? '保存失败');
      }
    }

    final location = await getSaveLocation(
      suggestedName: fileName,
      acceptedTypeGroups: const [
        XTypeGroup(label: 'JSON 文件', extensions: <String>['json']),
      ],
    );
    if (location == null) return null;
    await File(location.path).writeAsString(content);
    return location.path;
  }
}
