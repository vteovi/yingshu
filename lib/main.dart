import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app.dart';
import 'core/image_cache.dart';
import 'data/local_store.dart';
import 'state/app_state.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  // 海报解码后的内存缓存调大，避免每次切标签都要重新解码显示「加载中」。
  tuneImageMemoryCache();
  // 后台修剪海报磁盘缓存，别让它无限变大。
  unawaited(PosterFileCache.prune());

  final prefs = await SharedPreferences.getInstance();
  final state = AppState(LocalStore(prefs));
  await state.init();

  runApp(ChangeNotifierProvider<AppState>.value(
    value: state,
    child: const CmsPlayerApp(),
  ));
}
