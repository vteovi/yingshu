import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/constants.dart';
import '../core/file_export.dart';
import '../state/app_state.dart';
import 'lan_sync_page.dart';
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
                  style: TextStyle(
                      fontSize: 12, color: context.palette.textSecondary),
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
                  style: TextStyle(
                      fontSize: 12, color: context.palette.textSecondary),
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
              const Divider(height: 1, indent: 16, endIndent: 16),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
                child: Row(
                  children: [
                    const Icon(Icons.photo_size_select_large_rounded, size: 24),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('海报大小', style: TextStyle(fontSize: 15)),
                          const SizedBox(height: 2),
                          Text(
                            '手机上一行 3 / 2 / 1 张，平板按屏幕宽度自动加列',
                            style: TextStyle(
                                fontSize: 12,
                                color: context.palette.textSecondary),
                          ),
                        ],
                      ),
                    ),
                    SegmentedButton<PosterSize>(
                      showSelectedIcon: false,
                      style: const ButtonStyle(
                          visualDensity: VisualDensity.compact),
                      segments: [
                        for (final size in PosterSize.values)
                          ButtonSegment<PosterSize>(
                              value: size, label: Text(size.label)),
                      ],
                      selected: {app.posterSize},
                      onSelectionChanged: (value) =>
                          app.setPosterSize(value.first),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1, indent: 16, endIndent: 16),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.view_quilt_outlined, size: 24),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('海报样式',
                                  style: TextStyle(fontSize: 15)),
                              const SizedBox(height: 2),
                              Text(
                                '竖向＝2:3 竖版网格；横向＝16:10 横版卡片；原始比例＝按每张图自身比例排瀑布流',
                                style: TextStyle(
                                    fontSize: 12,
                                    color: context.palette.textSecondary),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    SizedBox(
                      width: double.infinity,
                      child: SegmentedButton<PosterMode>(
                        showSelectedIcon: false,
                        style: const ButtonStyle(
                            visualDensity: VisualDensity.compact),
                        segments: [
                          for (final mode in PosterMode.values)
                            ButtonSegment<PosterMode>(
                                value: mode, label: Text(mode.label)),
                        ],
                        selected: {app.posterMode},
                        onSelectionChanged: (value) =>
                            app.setPosterMode(value.first),
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1, indent: 16, endIndent: 16),
              SwitchListTile(
                secondary: const Icon(Icons.tune_rounded),
                title: const Text('显示视图切换按钮'),
                subtitle: Text(
                  '首页右上角那个「海报样式 / 海报大小」按钮，不需要就关掉腾出位置',
                  style: TextStyle(
                      fontSize: 12, color: context.palette.textSecondary),
                ),
                value: app.showViewSwitch,
                onChanged: (value) => app.setShowViewSwitch(value),
              ),
              const Divider(height: 1, indent: 16, endIndent: 16),
              SwitchListTile(
                secondary: const Icon(Icons.all_inbox_rounded),
                title: const Text('搜索自动加载更多'),
                subtitle: Text(
                  app.autoLoadMore
                      ? '打开：搜索结果滑到底部时自动加载下一页，不用手点'
                      : '关闭：底部显示「加载更多」按钮，翻页由你决定',
                  style: TextStyle(
                      fontSize: 12, color: context.palette.textSecondary),
                ),
                value: app.autoLoadMore,
                onChanged: (value) => app.setAutoLoadMore(value),
              ),
            ],
          ),
          const SizedBox(height: 20),
          _SectionTitle('播放'),
          _Card(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.screen_rotation_alt_outlined,
                            size: 24),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('播放屏幕方向',
                                  style: TextStyle(fontSize: 15)),
                              const SizedBox(height: 2),
                              Text(
                                app.playerOrientation.description,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: context.palette.textSecondary,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    SizedBox(
                      width: double.infinity,
                      child: SegmentedButton<PlayerOrientation>(
                        showSelectedIcon: false,
                        style: const ButtonStyle(
                            visualDensity: VisualDensity.compact),
                        segments: [
                          for (final mode in PlayerOrientation.values)
                            ButtonSegment<PlayerOrientation>(
                              value: mode,
                              label: Text(mode.label),
                            ),
                        ],
                        selected: {app.playerOrientation},
                        onSelectionChanged: (value) =>
                            app.setPlayerOrientation(value.first),
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1, indent: 16, endIndent: 16),
              SwitchListTile(
                secondary: const Icon(Icons.skip_next_outlined),
                title: const Text('自动连播下一集'),
                subtitle: Text(
                  '一集播完自动切下一集',
                  style: TextStyle(
                      fontSize: 12, color: context.palette.textSecondary),
                ),
                value: app.autoPlayNext,
                onChanged: (value) => app.setAutoPlayNext(value),
              ),
              const Divider(height: 1, indent: 16, endIndent: 16),
              SwitchListTile(
                secondary: const Icon(Icons.content_cut_rounded),
                title: const Text('自动跳过片头广告'),
                subtitle: Text(
                  '识别 m3u8 里拼在正片前面的广告段并直接跳过（默认关闭，识错会误跳正片）',
                  style: TextStyle(
                      fontSize: 12, color: context.palette.textSecondary),
                ),
                value: app.skipIntroAd,
                onChanged: (value) => app.setSkipIntroAd(value),
              ),
              const Divider(height: 1, indent: 16, endIndent: 16),
              SwitchListTile(
                secondary: const Icon(Icons.restore_rounded),
                title: const Text('记忆播放进度'),
                subtitle: Text(
                  '每 5 秒记录一次，下次进入自动续播',
                  style: TextStyle(
                      fontSize: 12, color: context.palette.textSecondary),
                ),
                value: app.rememberProgress,
                onChanged: (value) => app.setRememberProgress(value),
              ),
              const Divider(height: 1, indent: 16, endIndent: 16),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.fast_forward_rounded, size: 24),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('长按加速倍率',
                                  style: TextStyle(fontSize: 15)),
                              const SizedBox(height: 2),
                              Text(
                                '长按画面时临时加速到这一档，松手回到正常速度（默认 2×，最高 8×）',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: context.palette.textSecondary,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Text(
                          '${_formatRate(app.boostRate)}×',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                        ),
                      ],
                    ),
                    Slider(
                      min: kMinBoostRate,
                      max: kMaxBoostRate,
                      divisions:
                          ((kMaxBoostRate - kMinBoostRate) / 0.25).round(),
                      value: app.boostRate,
                      label: '${_formatRate(app.boostRate)}×',
                      onChanged: (value) => app.setBoostRate(value),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1, indent: 16, endIndent: 16),
              SwitchListTile(
                secondary: const Icon(Icons.speed_rounded),
                title: const Text('显示实时下载速度'),
                subtitle: Text(
                  '播放页左上角显示当前拉流速度（每隔几秒探测一次片源，会略微多占一点流量）',
                  style: TextStyle(
                      fontSize: 12, color: context.palette.textSecondary),
                ),
                value: app.showSpeedMeter,
                onChanged: (value) => app.setShowSpeedMeter(value),
              ),
            ],
          ),
          const SizedBox(height: 20),
          _SectionTitle('数据'),
          _Card(
            children: [
              ListTile(
                leading: const Icon(Icons.backup_outlined),
                title: const Text('备份数据'),
                subtitle: Text(
                  '把订阅源、收藏、历史、搜索记录和设置导出成一个 JSON 文件，自己选保存位置',
                  style: TextStyle(
                      fontSize: 12, color: context.palette.textSecondary),
                ),
                trailing: Icon(Icons.ios_share_rounded,
                    color: context.palette.textFaint),
                onTap: () => _backup(context, app),
              ),
              const Divider(height: 1, indent: 16, endIndent: 16),
              ListTile(
                leading: const Icon(Icons.settings_backup_restore_rounded),
                title: const Text('恢复数据'),
                subtitle: Text(
                  '从备份文件恢复：数据与现有内容合并（不覆盖），设置按备份还原',
                  style: TextStyle(
                      fontSize: 12, color: context.palette.textSecondary),
                ),
                trailing: Icon(Icons.file_open_outlined,
                    color: context.palette.textFaint),
                onTap: () => _restore(context, app),
              ),
              const Divider(height: 1, indent: 16, endIndent: 16),
              ListTile(
                leading: const Icon(Icons.devices_rounded),
                title: const Text('局域网设备同步'),
                subtitle: Text(
                  '同一 Wi‑Fi 下把订阅源、收藏、历史、设置合并到另一台（只增不覆盖）',
                  style: TextStyle(
                      fontSize: 12, color: context.palette.textSecondary),
                ),
                trailing:
                    Icon(Icons.chevron_right, color: context.palette.textFaint),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => const LanSyncPage()),
                ),
              ),
              const Divider(height: 1, indent: 16, endIndent: 16),
              ListTile(
                leading: const Icon(Icons.history),
                title: const Text('清空观看历史'),
                trailing: Text(
                  '${app.history.length}',
                  style:
                      TextStyle(fontSize: 12, color: context.palette.textFaint),
                ),
                onTap: app.history.isEmpty
                    ? null
                    : () => _confirm(
                        context, '清空观看历史', '确定删除全部观看记录吗？', app.clearHistory),
              ),
              const Divider(height: 1, indent: 16, endIndent: 16),
              ListTile(
                leading: const Icon(Icons.favorite_border),
                title: const Text('清空收藏'),
                trailing: Text(
                  '${app.favorites.length}',
                  style:
                      TextStyle(fontSize: 12, color: context.palette.textFaint),
                ),
                onTap: app.favorites.isEmpty
                    ? null
                    : () => _confirm(
                        context, '清空收藏', '确定删除全部收藏吗？', app.clearFavorites),
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
                  style:
                      TextStyle(fontSize: 12, color: context.palette.textFaint),
                ),
              ),
              const Divider(height: 1, indent: 16, endIndent: 16),
              ListTile(
                leading: Icon(Icons.info_outline),
                title: Text('版本'),
                trailing: Text(
                  'v$kAppVersion',
                  style:
                      TextStyle(fontSize: 12, color: context.palette.textFaint),
                ),
              ),
              const Divider(height: 1, indent: 16, endIndent: 16),
              ListTile(
                leading: Icon(Icons.movie_outlined),
                title: Text('播放内核'),
                trailing: Text(
                  '安卓 ExoPlayer / 桌面 libmpv',
                  style:
                      TextStyle(fontSize: 12, color: context.palette.textFaint),
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
              style: TextStyle(
                  fontSize: 12, height: 1.6, color: context.palette.textFaint),
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
                style: TextStyle(
                    fontSize: 12,
                    height: 1.5,
                    color: context.palette.textSecondary),
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

  Future<void> _backup(BuildContext context, AppState app) async {
    final now = DateTime.now();
    final stamp = '${now.year}'
        '${now.month.toString().padLeft(2, '0')}'
        '${now.day.toString().padLeft(2, '0')}-'
        '${now.hour.toString().padLeft(2, '0')}'
        '${now.minute.toString().padLeft(2, '0')}';
    try {
      final content = app.exportBackupJson();
      final saved = await FileExport.saveText(
        fileName: 'CineHub-backup-$stamp.json',
        content: content,
      );
      if (!context.mounted) return;
      if (saved == null) return; // 用户取消了保存
      _snack(context,
          '备份已保存（订阅源 ${app.sources.length} 个、收藏 ${app.favorites.length} 条）');
    } catch (error) {
      if (!context.mounted) return;
      _snack(context, '备份失败：${_describeError(error)}');
    }
  }

  Future<void> _restore(BuildContext context, AppState app) async {
    String? content;
    try {
      content = await FileExport.pickText();
    } catch (error) {
      if (!context.mounted) return;
      _snack(context, '打开文件失败：${_describeError(error)}');
      return;
    }
    if (content == null || !context.mounted) return;

    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('恢复数据'),
        content: const Text(
          '订阅源、收藏、历史、搜索记录会和本机现有内容合并（本机已有的保留，重复的跳过）；'
          '设置会按备份文件还原。确定继续吗？',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('恢复')),
        ],
      ),
    );
    if (ok != true) return;

    try {
      final result = await app.restoreBackupJson(content);
      if (!context.mounted) return;
      _snack(
        context,
        result.total == 0
            ? '备份里的内容本机都已经有了，没有新增'
            : '恢复完成：新增订阅源 ${result.sources} 个、收藏 ${result.favorites} 条、'
                '历史 ${result.history} 条、搜索记录 ${result.searchKeywords} 条，'
                '应用设置 ${result.settings} 项',
      );
    } on FormatException catch (error) {
      if (!context.mounted) return;
      _snack(context, '恢复失败：${error.message}');
    } catch (error) {
      if (!context.mounted) return;
      _snack(context, '恢复失败：${_describeError(error)}');
    }
  }

  void _snack(BuildContext context, String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
          SnackBar(content: Text(text), duration: const Duration(seconds: 4)));
  }

  String _describeError(Object error) =>
      error.toString().replaceFirst('Exception: ', '');

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
          TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('确定')),
        ],
      ),
    );
    if (ok == true) await action();
  }
}

/// 倍率显示：整数倍不带小数，其余保留两位有效的小数（1.25×、2×、3.5×）。
String _formatRate(double value) {
  final rounded = value.toStringAsFixed(2);
  if (rounded.endsWith('.00')) return rounded.substring(0, rounded.length - 3);
  if (rounded.endsWith('0')) return rounded.substring(0, rounded.length - 1);
  return rounded;
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
        style: TextStyle(
            fontSize: 12, letterSpacing: 1.2, color: context.palette.textFaint),
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
      leading: Icon(icon,
          color: selected ? Theme.of(context).colorScheme.primary : null),
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
          ? Icon(Icons.check_circle,
              size: 20, color: Theme.of(context).colorScheme.primary)
          : null,
      onTap: onTap,
    );
  }
}
