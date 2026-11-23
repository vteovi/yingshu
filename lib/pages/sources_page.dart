import 'dart:convert';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../data/tvbox_config.dart';
import '../models/cms_source.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';
import '../widgets/brand_mark.dart';
import '../widgets/state_views.dart';
import 'source_edit_page.dart';
import '../theme/app_palette.dart';

/// 订阅源列表：新增 / 编辑 / 启用停用 / 删除 / 批量导入导出。
class SourcesPage extends StatelessWidget {
  const SourcesPage({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final sources = app.sources;

    return Scaffold(
      appBar: AppBar(
        title: const Text('订阅源管理'),
        actions: [
          PopupMenuButton<String>(
            onSelected: (value) {
              switch (value) {
                case 'text':
                  _importText(context, app);
                  break;
                case 'url':
                  _importUrl(context, app);
                  break;
                case 'file':
                  _importFile(context, app);
                  break;
                case 'copy':
                  _copyConfig(context, app);
                  break;
              }
            },
            itemBuilder: (context) => const [
              PopupMenuItem(value: 'url', child: Text('从订阅链接导入（支持 TVBox）')),
              PopupMenuItem(value: 'text', child: Text('粘贴文本 / TVBox 配置导入')),
              PopupMenuItem(value: 'file', child: Text('从本地 JSON 文件导入')),
              PopupMenuDivider(),
              PopupMenuItem(value: 'copy', child: Text('复制源配置（JSON）')),
            ],
          ),
        ],
      ),
      body: sources.isEmpty
          ? EmptyView(
              badge: const BrandMark(size: 88),
              title: '影枢还没有订阅源',
              subtitle: '添加苹果CMS v10 采集接口地址，\n例如 https://你的域名/api.php/provide/vod/',
              actionLabel: '添加第一个源',
              onAction: () => _openEdit(context, null),
            )
          : ListView.separated(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
              itemCount: sources.length,
              separatorBuilder: (_, __) => const SizedBox(height: 10),
              itemBuilder: (context, i) {
                final source = sources[i];
                return _SourceCard(
                  source: source,
                  isCurrent: app.currentSource?.id == source.id,
                  onTap: () => _openEdit(context, source),
                  onToggle: (value) => app.toggleSource(source.id, value),
                  onDelete: () => _confirmDelete(context, app, source),
                );
              },
            ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openEdit(context, null),
        icon: const Icon(Icons.add),
        label: const Text('添加源'),
      ),
    );
  }

  void _openEdit(BuildContext context, CmsSource? source) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => SourceEditPage(source: source)),
    );
  }

  Future<void> _confirmDelete(BuildContext context, AppState app, CmsSource source) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除订阅源'),
        content: Text('确定删除「${source.name}」吗？\n与它关联的收藏和观看记录也会一并清理。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('删除')),
        ],
      ),
    );
    if (ok != true) return;
    await app.removeSource(source.id);
    if (!context.mounted) return;
    final cleaned = app.lastRemovedSourceCleanup;
    _snack(context, cleaned > 0 ? '已删除，同时清理了 $cleaned 条收藏/历史记录' : '已删除');
  }

  Future<void> _importText(BuildContext context, AppState app) async {
    final controller = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('粘贴订阅文本'),
        content: SizedBox(
          width: 420,
          child: TextField(
            controller: controller,
            maxLines: 8,
            decoration: const InputDecoration(
              hintText: '每行一条：站点名,https://xxx.com/api.php/provide/vod/\n'
                  '也可以直接粘贴影枢 JSON 或 TVBox 配置（含 sites / urls）',
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: const Text('导入'),
          ),
        ],
      ),
    );
    Future<void>.delayed(const Duration(milliseconds: 500), controller.dispose);
    if (text == null || text.trim().isEmpty) return;

    await _importBundleText(context, app, text);
  }

  /// 粘贴内容可能是 TVBox 配置：先落库 sites，再把 urls 里的子配置拉下来。
  Future<void> _importBundleText(BuildContext context, AppState app, String text) async {
    final bundle = parseSourceBundle(text);
    if (bundle.isEmpty) {
      if (!context.mounted) return;
      _snack(context, '没有解析到有效的接口地址');
      return;
    }

    var added = await app.importSources(bundle.sources);
    for (final url in bundle.subscriptionUrls) {
      try {
        added += await app.importFromUrl(url);
      } catch (_) {
        // 单个子配置失败不影响其它源
      }
    }
    if (!context.mounted) return;
    _snack(context, added == 0 ? '这些源都已存在，未新增' : '导入成功，新增 $added 个源');
  }

  /// 本地 JSON / TXT 文件导入（TVBox 配置文件、影枢导出文件都可以）。
  Future<void> _importFile(BuildContext context, AppState app) async {
    const typeGroup = XTypeGroup(
      label: '配置文件',
      extensions: <String>['json', 'txt'],
    );

    XFile? picked;
    try {
      picked = await openFile(acceptedTypeGroups: const <XTypeGroup>[typeGroup]);
    } catch (error) {
      if (!context.mounted) return;
      _snack(context, '打开文件选择器失败：$error');
      return;
    }
    if (picked == null) return;

    String text;
    try {
      text = await picked.readAsString();
    } catch (error) {
      if (!context.mounted) return;
      _snack(context, '读取文件失败：$error');
      return;
    }

    final bundle = parseSourceBundle(text);
    final name = picked.name;
    if (bundle.isEmpty) {
      if (!context.mounted) return;
      _snack(context, '「$name」里没有找到可用的接口地址');
      return;
    }

    var added = await app.importSources(bundle.sources);
    for (final url in bundle.subscriptionUrls) {
      try {
        added += await app.importFromUrl(url);
      } catch (_) {}
    }
    if (!context.mounted) return;
    _snack(context, added == 0
        ? '「$name」里的源都已存在'
        : '从「$name」导入成功，新增 $added 个源');
  }

  Future<void> _importUrl(BuildContext context, AppState app) async {
    final controller = TextEditingController();
    final url = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('从订阅链接导入'),
        content: SizedBox(
          width: 420,
          child: TextField(
            controller: controller,
            decoration: const InputDecoration(
              hintText: 'https://xxx.com/sources.json',
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text.trim()),
            child: const Text('拉取'),
          ),
        ],
      ),
    );
    Future<void>.delayed(const Duration(milliseconds: 500), controller.dispose);
    if (url == null || url.isEmpty) return;

    try {
      final added = await app.importFromUrl(url);
      if (!context.mounted) return;
      _snack(context, added == 0 ? '订阅内容中的源都已存在' : '订阅导入成功，新增 $added 个源');
    } catch (error) {
      if (!context.mounted) return;
      _snack(context, '订阅导入失败：$error');
    }
  }

  Future<void> _copyConfig(BuildContext context, AppState app) async {
    final data = jsonEncode(app.sources.map((s) => s.toJson()).toList());
    await Clipboard.setData(ClipboardData(text: data));
    if (!context.mounted) return;
    _snack(context, '已复制 ${app.sources.length} 个源的配置到剪贴板');
  }

  void _snack(BuildContext context, String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}

class _SourceCard extends StatelessWidget {
  const _SourceCard({
    required this.source,
    required this.isCurrent,
    required this.onTap,
    required this.onToggle,
    required this.onDelete,
  });

  final CmsSource source;
  final bool isCurrent;
  final VoidCallback onTap;
  final ValueChanged<bool> onToggle;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: context.palette.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: context.palette.border),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            source.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                          ),
                        ),
                        if (isCurrent) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: const Color(0x337FA6FF),
                              borderRadius: BorderRadius.circular(5),
                            ),
                            child: const Text(
                              '当前',
                              style: TextStyle(fontSize: 10, color: Color(0xFFAFC8FF)),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      source.api,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11, color: context.palette.textFaint),
                    ),
                    if (source.note.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        source.note,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 11, color: context.palette.textSecondary),
                      ),
                    ],
                  ],
                ),
              ),
              IconButton(
                tooltip: '删除',
                onPressed: onDelete,
                icon: Icon(Icons.delete_outline, size: 19, color: context.palette.textFaint),
              ),
              Switch(
                value: source.enabled,
                onChanged: onToggle,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
