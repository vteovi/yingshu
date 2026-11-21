import 'package:flutter/material.dart';

import 'pages/root_shell.dart';
import 'theme/app_theme.dart';

class CmsPlayerApp extends StatelessWidget {
  const CmsPlayerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '影枢 CineHub',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark(),
      home: const RootShell(),
    );
  }
}
