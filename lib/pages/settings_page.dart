import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/constants.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';
import 'sources_page.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();

    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          _SectionTitle('订阅'),
          _Card(
            children: [
              ListTile(
                leading: const Icon(Icons.dns_outlined),
                title: const Text('订阅源管理'),
                subtitle: Text(
                  '共 ${app.sources.length} 个源 · ${app.enabledSources.length} 个已启用',
                  style: const TextStyle(fontSize: 12, color: Colors.white54),
                ),
                trailing: const Icon(Icons.chevron_right, size: 20),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const SourcesPage()),
                ),
              ),
              const Divider(height: 1, indent: 16, endIndent: 16),
              ListTile(
                leading: const Icon(Icons.badge_outlined),
                title: const Text('请求 User-Agent'),
                subtitle: Text(
                  app.userAgent,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12, color: Colors.white54),
                ),
                trailing: const Icon(Icons.edit_outlined, size: 18),
                onTap: () => _editUserAgent(context, app),
              ),
            ],
          ),
          const SizedBox(height: 20),
          _SectionTitle('播放'),
          _Card(
            children: [
              SwitchListTile(
                secondary: const Icon(Icons.skip_next_outlined),
                title: const Text('自动连播下一集'),
                subtitle: const Text(
                  '一集播完自动切下一集',
                  style: TextStyle(fontSize: 12, color: Colors.white54),
                ),
                value: app.autoPlayNext,
                onChanged: (value) => app.setAutoPlayNext(value),
              ),
              const Divider(height: 1, indent: 16, endIndent: 16),
              SwitchListTile(
                secondary: const Icon(Icons.restore_rounded),
                title: const Text('记忆播放进度'),
                subtitle: const Text(
                  '每 5 秒记录一次，下次进入自动续播',
                  style: TextStyle(fontSize: 12, color: Colors.white54),
                ),
                value: app.rememberProgress,
                onChanged: (value) => app.setRememberProgress(value),
              ),
            ],
          ),
          const SizedBox(height: 20),
          _SectionTitle('数据'),
          _Card(
            children: [
              ListTile(
                leading: const Icon(Icons.history),
                title: const Text('清空观看历史'),
                trailing: Text(
                  '${app.history.length}',
                  style: const TextStyle(fontSize: 12, color: Colors.white38),
                ),
                onTap: app.history.isEmpty
                    ? null
                    : () => _confirm(context, '清空观看历史', '确定删除全部观看记录吗？', app.clearHistory),
              ),
              const Divider(height: 1, indent: 16, endIndent: 16),
              ListTile(
                leading: const Icon(Icons.favorite_border),
                title: const Text('清空收藏'),
                trailing: Text(
                  '${app.favorites.length}',
                  style: const TextStyle(fontSize: 12, color: Colors.white38),
                ),
                onTap: app.favorites.isEmpty
                    ? null
                    : () => _confirm(context, '清空收藏', '确定删除全部收藏吗？', app.clearFavorites),
              ),
            ],
          ),
          const SizedBox(height: 20),
          _SectionTitle('关于'),
          _Card(
            children: [
              const ListTile(
                leading: Icon(Icons.apps_rounded),
                title: Text('应用名称'),
                trailing: Text(
                  '$kAppName · $kAppNameEn',
                  style: TextStyle(fontSize: 12, color: Colors.white38),
                ),
              ),
              const Divider(height: 1, indent: 16, endIndent: 16),
              const ListTile(
                leading: Icon(Icons.info_outline),
                title: Text('版本'),
                trailing: Text(
                  'v$kAppVersion',
                  style: TextStyle(fontSize: 12, color: Colors.white38),
                ),
              ),
              const Divider(height: 1, indent: 16, endIndent: 16),
              const ListTile(
                leading: Icon(Icons.movie_outlined),
                title: Text('播放内核'),
                trailing: Text(
                  'media_kit / libmpv',
                  style: TextStyle(fontSize: 12, color: Colors.white38),
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              '本应用只提供播放器与订阅源管理，不内置任何影视源。'
              '请自行添加可用的苹果CMS v10 采集接口，并确保内容来源合法。',
              style: TextStyle(fontSize: 12, height: 1.6, color: Colors.white38),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _editUserAgent(BuildContext context, AppState app) async {
    final controller = TextEditingController(text: app.userAgent);
    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('请求 User-Agent'),
        content: TextField(
          controller: controller,
          maxLines: 3,
          decoration: const InputDecoration(hintText: '留空则恢复默认 UA'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    Future<void>.delayed(const Duration(milliseconds: 500), controller.dispose);
    if (result != null) await app.setUserAgent(result);
  }

  Future<void> _confirm(
    BuildContext context,
    String title,
    String message,
    Future<void> Function() action,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('确定')),
        ],
      ),
    );
    if (ok == true) await action();
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
      child: Text(
        text,
        style: const TextStyle(fontSize: 12, letterSpacing: 1.2, color: Colors.white38),
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(children: children),
    );
  }
}
