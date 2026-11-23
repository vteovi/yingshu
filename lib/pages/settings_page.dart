import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/constants.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';
import 'sources_page.dart';
import '../theme/app_palette.dart';

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
                  style: TextStyle(fontSize: 12, color: context.palette.textSecondary),
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
                  style: TextStyle(fontSize: 12, color: context.palette.textSecondary),
                ),
                trailing: const Icon(Icons.edit_outlined, size: 18),
                onTap: () => _editUserAgent(context, app),
              ),
            ],
          ),
          const SizedBox(height: 20),
          _SectionTitle('外观'),
          _Card(
            children: [
              _ThemeTile(
                mode: ThemeMode.system,
                icon: Icons.brightness_auto_outlined,
                title: '跟随系统',
                subtitle: '系统切换深色/浅色时自动跟随（默认）',
                current: app.themeMode,
                onTap: () => app.setThemeMode(ThemeMode.system),
              ),
              const Divider(height: 1, indent: 16, endIndent: 16),
              _ThemeTile(
                mode: ThemeMode.light,
                icon: Icons.light_mode_outlined,
                title: '浅色',
                subtitle: '白底深字，适合白天或强光环境',
                current: app.themeMode,
                onTap: () => app.setThemeMode(ThemeMode.light),
              ),
              const Divider(height: 1, indent: 16, endIndent: 16),
              _ThemeTile(
                mode: ThemeMode.dark,
                icon: Icons.dark_mode_outlined,
                title: '深色（OLED 纯黑）',
                subtitle: '背景与卡片都是 #000000，屏幕像素不发光，最省电',
                current: app.themeMode,
                onTap: () => app.setThemeMode(ThemeMode.dark),
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
                subtitle: Text(
                  '一集播完自动切下一集',
                  style: TextStyle(fontSize: 12, color: context.palette.textSecondary),
                ),
                value: app.autoPlayNext,
                onChanged: (value) => app.setAutoPlayNext(value),
              ),
              const Divider(height: 1, indent: 16, endIndent: 16),
              SwitchListTile(
                secondary: const Icon(Icons.restore_rounded),
                title: const Text('记忆播放进度'),
                subtitle: Text(
                  '每 5 秒记录一次，下次进入自动续播',
                  style: TextStyle(fontSize: 12, color: context.palette.textSecondary),
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
                  style: TextStyle(fontSize: 12, color: context.palette.textFaint),
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
                  style: TextStyle(fontSize: 12, color: context.palette.textFaint),
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
              ListTile(
                leading: Icon(Icons.apps_rounded),
                title: Text('应用名称'),
                trailing: Text(
                  '$kAppName · $kAppNameEn',
                  style: TextStyle(fontSize: 12, color: context.palette.textFaint),
                ),
              ),
              const Divider(height: 1, indent: 16, endIndent: 16),
              ListTile(
                leading: Icon(Icons.info_outline),
                title: Text('版本'),
                trailing: Text(
                  'v$kAppVersion',
                  style: TextStyle(fontSize: 12, color: context.palette.textFaint),
                ),
              ),
              const Divider(height: 1, indent: 16, endIndent: 16),
              ListTile(
                leading: Icon(Icons.movie_outlined),
                title: Text('播放内核'),
                trailing: Text(
                  'media_kit / libmpv',
                  style: TextStyle(fontSize: 12, color: context.palette.textFaint),
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              '本应用只提供播放器与订阅源管理，不内置任何影视源。'
              '请自行添加可用的苹果CMS v10 采集接口，并确保内容来源合法。',
              style: TextStyle(fontSize: 12, height: 1.6, color: context.palette.textFaint),
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
        contentPadding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '可直接编辑下方文本，也可点选一个内置预设后保存。'
                '部分源会按 UA 返回不同内容，切换后建议重新拉取首页。',
                style: TextStyle(fontSize: 12, height: 1.5, color: context.palette.textSecondary),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  for (final preset in kUserAgentPresets)
                    ActionChip(
                      label: Text(preset.label),
                      avatar: const Icon(Icons.bolt_outlined, size: 14),
                      onPressed: () {
                        controller.text = preset.value;
                        controller.selection = TextSelection.collapsed(
                          offset: controller.text.length,
                        );
                      },
                    ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                maxLines: 4,
                minLines: 2,
                decoration: const InputDecoration(
                  labelText: 'User-Agent',
                  hintText: '留空则恢复默认 UA',
                ),
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () {
                    controller.text = kDefaultUserAgent;
                    controller.selection = TextSelection.collapsed(
                      offset: controller.text.length,
                    );
                  },
                  icon: const Icon(Icons.restart_alt, size: 16),
                  label: const Text('恢复默认'),
                ),
              ),
            ],
          ),
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
        style: TextStyle(fontSize: 12, letterSpacing: 1.2, color: context.palette.textFaint),
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
        color: context.palette.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: context.palette.border),
      ),
      child: Column(children: children),
    );
  }
}

/// 外观模式单项：选中时右侧显示勾选。
class _ThemeTile extends StatelessWidget {
  const _ThemeTile({
    required this.mode,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.current,
    required this.onTap,
  });

  final ThemeMode mode;
  final IconData icon;
  final String title;
  final String subtitle;
  final ThemeMode current;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final selected = mode == current;
    return ListTile(
      leading: Icon(icon, color: selected ? Theme.of(context).colorScheme.primary : null),
      title: Text(
        title,
        style: TextStyle(
          fontSize: 15,
          fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
        ),
      ),
      subtitle: Text(
        subtitle,
        style: TextStyle(fontSize: 12, color: context.palette.textSecondary),
      ),
      trailing: selected
          ? Icon(Icons.check_circle, size: 20, color: Theme.of(context).colorScheme.primary)
          : null,
      onTap: onTap,
    );
  }
}
