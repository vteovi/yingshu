import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'pages/root_shell.dart';
import 'state/app_state.dart';
import 'theme/app_theme.dart';

class CmsPlayerApp extends StatelessWidget {
  const CmsPlayerApp({super.key});

  @override
  Widget build(BuildContext context) {
    final mode = context.watch<AppState>().themeMode;

    return MaterialApp(
      title: '影枢 CineHub',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: mode,
      home: const RootShell(),
    );
  }
}
