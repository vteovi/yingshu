import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../core/clip_url.dart';
import '../core/file_export.dart';
import '../data/tvbox_config.dart';
import '../models/cms_source.dart';
import '../models/source_health.dart';
import '../state/app_state.dart';
import '../widgets/brand_mark.dart';
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
          IconButton(
            tooltip: app.checking ? '正在检测…' : '检测可用性',
            onPressed: app.checking ? null : () => _runCheck(context, app),
            icon: const Icon(Icons.network_check),
          ),
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
                case 'clear':
                  _clearUnavailable(context, app);
                  break;
                case 'export':
                  _exportSources(context, app);
                  break;
              }
            },
            itemBuilder: (context) => const [
              PopupMenuItem(value: 'url', child: Text('从订阅链接导入（支持 TVBox）')),
              PopupMenuItem(value: 'text', child: Text('粘贴文本 / TVBox 配置导入')),
              PopupMenuItem(value: 'file', child: Text('从本地 JSON 文件导入')),
              PopupMenuDivider(),
              PopupMenuItem(value: 'copy', child: Text('复制源配置（JSON）')),
              PopupMenuItem(value: 'export', child: Text('导出全部源（JSON 文件）')),
              PopupMenuDivider(),
              PopupMenuItem(value: 'clear', child: Text('清理失效源')),
            ],
          ),
        ],
        bottom: app.checking
            ? PreferredSize(
                preferredSize: const Size.fromHeight(3),
                child: LinearProgressIndicator(
                  value: app.checkProgress,
                  minHeight: 3,
                ),
              )
            : null,
      ),
      body: sources.isEmpty
          ? _EmptySources(
              onManual: () => _openEdit(context, null),
              onUrl: () => _importUrl(context, app),
              onText: () => _importText(context, app),
              onFile: () => _importFile(context, app),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (app.checking)
                  _CheckBanner(
                    text: '正在检测 ${app.checkDone}/${app.checkTotal} 个源'
                        ' · 可用 ${app.availableCount} · 不可用 ${app.unavailableCount}',
                  )
                else if (app.availableCount + app.unavailableCount > 0)
                  _CheckBanner(
                    text:
                        '可用 ${app.availableCount} 个 · 不可用 ${app.unavailableCount} 个',
                    showDot: false,
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                  child: Text(
                    '点卡片可编辑 · 长按可复制接口地址',
                    style: TextStyle(
                        fontSize: 11, color: context.palette.textFaint),
                  ),
                ),
                Expanded(
                  child: ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
                    itemCount: sources.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 10),
                    itemBuilder: (context, i) {
                      final source = sources[i];
                      return _SourceCard(
                        source: source,
                        health: app.healthOf(source.id),
                        checking: app.isCheckingSource(source.id),
                        isCurrent: app.currentSource?.id == source.id,
                        onTap: () => _openEdit(context, source),
                        onCheck: () => _runSingleCheck(context, app, source),
                        onToggle: (value) => app.toggleSource(source.id, value),
                        onCopy: () => _copySourceApi(context, source),
                      );
                    },
                  ),
                ),
              ],
            ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openEdit(context, null),
        icon: const Icon(Icons.add),
        label: const Text('添加源'),
      ),
    );
  }

  Future<void> _runCheck(BuildContext context, AppState app) async {
    final summary = await app.checkSources();
    if (!context.mounted) return;
    if (summary.total == 0) {
      _snack(context, '没有可检测的源');
      return;
    }
    _snack(
      context,
      summary.unavailable == 0
          ? '全部 ${summary.total} 个源可用，已保持在前面并启用'
          : '${summary.available} 个可用已启用排在前，'
              '${summary.unavailable} 个不可用已关闭排在后',
    );
  }

  Future<void> _runSingleCheck(
      BuildContext context, AppState app, CmsSource source) async {
    final health = await app.checkSource(source.id);
    if (!context.mounted) return;
    if (health == null) {
      _snack(context, '这个源已经不在列表里了');
      return;
    }
    if (health.isAvailable) {
      final latency = health.latencyLabel;
      _snack(
        context,
        '「${source.name}」可用${latency.isEmpty ? '' : ' · $latency'}'
        '${health.message.isEmpty ? '' : ' · ${health.message}'}',
      );
    } else {
      _snack(context, '「${source.name}」不可用 · ${health.message}');
    }
  }

  /// 长按卡片：把这个源的接口地址复制到剪贴板。
  Future<void> _copySourceApi(BuildContext context, CmsSource source) async {
    final api = source.api.trim();
    if (api.isEmpty) {
      _snack(context, '这个源没有填写接口地址');
      return;
    }
    await Clipboard.setData(ClipboardData(text: api));
    if (!context.mounted) return;
    _snack(context, '已复制「${source.name}」的接口地址');
  }

  void _openEdit(BuildContext context, CmsSource? source) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => SourceEditPage(source: source)),
    );
  }

  /// 读剪贴板；拿不到就返回 null（桌面端某些环境会抛异常）。
  Future<String?> _readClipboard() async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      return data?.text;
    } catch (_) {
      return null;
    }
  }

  Future<void> _importText(BuildContext context, AppState app) async {
    // 剪贴板里的整段文本原样铺进去：可能是一行条线路、一坨影枢 JSON，
    // 也可能是一整份 TVBox 配置，解析交给下面的 _importBundleText 去判断。
    final seed = ((await _readClipboard()) ?? '').trim();
    final controller = TextEditingController(text: seed);
    if (seed.isNotEmpty) {
      controller.selection = TextSelection.collapsed(offset: seed.length);
    }
    final text = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('粘贴订阅文本'),
        content: SizedBox(
          width: 420,
          child: TextField(
            controller: controller,
            maxLines: 8,
            decoration: InputDecoration(
              hintText: '每行一条：站点名,https://xxx.com/api.php/provide/vod/\n'
                  '也可以直接粘贴影枢 JSON 或 TVBox 配置（含 sites / urls）',
              helperText: seed.isEmpty ? null : '已填入剪贴板里的文本，可直接导入',
            ),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('取消')),
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
  Future<void> _importBundleText(
      BuildContext context, AppState app, String text) async {
    final bundle = parseSourceBundle(text);
    if (bundle.isEmpty) {
      if (!context.mounted) return;
      final hint = describeUnsupportedBody(text);
      _snack(context, hint ?? '没有解析到有效的接口地址');
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
    _snack(
        context,
        added == 0
            ? '这些源都已存在，原有 ${app.sources.length} 个源保留'
            : '导入成功，新增 $added 个源 · 原有 ${app.sources.length - added} 个源保留');
  }

  /// 本地 JSON / TXT 文件导入（TVBox 配置文件、影枢导出文件都可以）。
  ///
  /// 走 [FileExport.pickText]：安卓用系统「打开文件」(SAF)，桌面用打开对话框，
  /// 和「恢复数据」共用同一条原生通道，不用额外依赖插件。
  Future<void> _importFile(BuildContext context, AppState app) async {
    String? text;
    try {
      text = await FileExport.pickText(extensions: const ['json', 'txt']);
    } catch (error) {
      if (!context.mounted) return;
      _snack(context, '打开文件选择器失败：$error');
      return;
    }
    if (text == null) return; // 用户取消

    final bundle = parseSourceBundle(text);
    if (bundle.isEmpty) {
      if (!context.mounted) return;
      final hint = describeUnsupportedBody(text);
      _snack(context, hint == null ? '这个文件里没有找到可用的接口地址' : '导入失败：$hint');
      return;
    }

    var added = await app.importSources(bundle.sources);
    for (final url in bundle.subscriptionUrls) {
      try {
        added += await app.importFromUrl(url);
      } catch (_) {}
    }
    if (!context.mounted) return;
    _snack(
      context,
      added == 0
          ? '文件里的源都已存在，原有 ${app.sources.length} 个源保留'
          : '从文件导入成功，新增 $added 个源 · 原有 ${app.sources.length - added} 个源保留',
    );
  }

  Future<void> _importUrl(BuildContext context, AppState app) async {
    // 剪贴板里是链接就自动填进去，光标停在末尾，直接点「拉取」就行
    final seed = findUrlInText(await _readClipboard()) ?? '';
    final controller = TextEditingController(text: seed);
    if (seed.isNotEmpty) {
      controller.selection = TextSelection.collapsed(offset: seed.length);
    }
    final url = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('从订阅链接导入'),
        content: SizedBox(
          width: 420,
          child: TextField(
            controller: controller,
            keyboardType: TextInputType.url,
            autocorrect: false,
            decoration: InputDecoration(
              hintText: 'https://xxx.com/sources.json',
              helperText: seed.isEmpty ? null : '已填入剪贴板里的链接，可直接拉取',
            ),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('取消')),
          FilledButton(
            onPressed: () =>
                Navigator.pop(dialogContext, controller.text.trim()),
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
      _snack(
          context,
          added == 0
              ? '订阅内容中的源都已存在，原有 ${app.sources.length} 个源保留'
              : '订阅导入成功，新增 $added 个源 · 原有 ${app.sources.length - added} 个源保留');
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

  /// 导出全部源：安卓走系统「另存为」，桌面走保存对话框；
  /// 都不支持时退回到可复制的文本框。
  Future<void> _exportSources(BuildContext context, AppState app) async {
    if (app.sources.isEmpty) {
      _snack(context, '还没有订阅源可导出');
      return;
    }
    final data = jsonEncode(app.sources.map((s) => s.toJson()).toList());
    final name =
        'CineHub-sources-${DateTime.now().millisecondsSinceEpoch}.json';

    String? saved;
    var failed = false;
    try {
      saved = await FileExport.saveText(fileName: name, content: data);
    } catch (_) {
      failed = true;
    }

    if (!context.mounted) return;
    if (saved != null) {
      _snack(context, '已导出 ${app.sources.length} 个源 · $saved');
      return;
    }
    if (!failed) {
      // 用户在系统选择器里点了取消
      _snack(context, '已取消导出');
      return;
    }
    await _showExportFallback(context, app, data);
  }

  Future<void> _showExportFallback(
      BuildContext context, AppState app, String data) async {
    var copied = false;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('导出 ${app.sources.length} 个源'),
        content: SizedBox(
          width: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '当前设备不支持直接另存文件，可以复制下面的 JSON 自行保存。',
                style: TextStyle(
                    fontSize: 12, color: context.palette.textSecondary),
              ),
              const SizedBox(height: 10),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 260),
                child: SingleChildScrollView(
                  child: SelectableText(
                    data,
                    style: const TextStyle(
                        fontSize: 11, height: 1.35, fontFamily: 'monospace'),
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('关闭'),
          ),
          FilledButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: data));
              copied = true;
              if (dialogContext.mounted) Navigator.pop(dialogContext);
            },
            child: const Text('复制 JSON'),
          ),
        ],
      ),
    );
    if (!context.mounted || !copied) return;
    _snack(context, '已复制 ${app.sources.length} 个源的 JSON');
  }

  /// 清理失效源：删掉检测结果为「不可用」的源，其它源不动。
  Future<void> _clearUnavailable(BuildContext context, AppState app) async {
    final bad = app.sources
        .where((s) => app.healthOf(s.id).isUnavailable)
        .toList(growable: false);
    if (bad.isEmpty) {
      _snack(context, '没有检测到失效源，先点右上角「检测可用性」再清理');
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('清理失效源'),
        content: Text(
          '将删除 ${bad.length} 个检测为不可用的源：\n'
          '${bad.take(6).map((s) => '· ${s.name}').join('\n')}'
          '${bad.length > 6 ? '\n… 还有 ${bad.length - 6} 个' : ''}\n\n'
          '与这些源关联的收藏和观看记录也会一并清理，确定继续吗？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('清理'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    var removed = 0;
    for (final source in bad) {
      if (!app.sources.any((s) => s.id == source.id)) continue;
      await app.removeSource(source.id);
      removed++;
    }
    if (!context.mounted) return;
    _snack(context, '已清理 $removed 个失效源，剩余 ${app.sources.length} 个');
  }

  void _snack(BuildContext context, String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}

/// 一个源都没有时的引导页：把四种添加方式都摊开，用户按自己的情况点。
///
/// 之前只给一个「添加第一个源」，等于默认所有人都是手动填接口地址；
/// 实际大多数人手上是 TVBox 订阅链接或者一份配置文件。
class _EmptySources extends StatelessWidget {
  const _EmptySources({
    required this.onManual,
    required this.onUrl,
    required this.onText,
    required this.onFile,
  });

  final VoidCallback onManual;
  final VoidCallback onUrl;
  final VoidCallback onText;
  final VoidCallback onFile;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return ListView(
      padding: const EdgeInsets.fromLTRB(28, 8, 28, 32),
      children: [
        const SizedBox(height: 24),
        const Center(child: BrandMark(size: 84)),
        const SizedBox(height: 18),
        const Text(
          '还没有订阅源',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        Text(
          '添加苹果CMS v10 采集接口，或直接导入 TVBox 订阅配置。\n'
          '四种方式任选一种，导入后可以逐个编辑。',
          textAlign: TextAlign.center,
          style: TextStyle(
              fontSize: 12, height: 1.6, color: palette.textSecondary),
        ),
        const SizedBox(height: 26),
        FilledButton.icon(
          onPressed: onManual,
          icon: const Icon(Icons.add_link_rounded),
          label: const Text('手动添加一个接口'),
        ),
        const SizedBox(height: 20),
        Text(
          '或者从现成的配置导入',
          textAlign: TextAlign.center,
          style: TextStyle(
              fontSize: 12, letterSpacing: 0.4, color: palette.textFaint),
        ),
        const SizedBox(height: 12),
        _EntryButton(
          icon: Icons.link_rounded,
          title: '从订阅链接导入',
          subtitle: '支持 TVBox 订阅地址，也支持本站导出的源列表链接',
          onTap: onUrl,
        ),
        const SizedBox(height: 10),
        _EntryButton(
          icon: Icons.content_paste_rounded,
          title: '粘贴文本 / TVBox 配置导入',
          subtitle: '把整段 JSON 或 TVBox 配置（含 sites / urls）粘进来即可',
          onTap: onText,
        ),
        const SizedBox(height: 10),
        _EntryButton(
          icon: Icons.folder_open_rounded,
          title: '从本地文件导入',
          subtitle: '选择 .json / .txt 配置文件，用系统文件管理器挑选',
          onTap: onFile,
        ),
      ],
    );
  }
}

/// 空状态里的整行入口按钮：图标 + 标题 + 说明，整块都能点。
class _EntryButton extends StatelessWidget {
  const _EntryButton({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final primary = Theme.of(context).colorScheme.primary;
    return Material(
      color: palette.surface,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 13, 12, 13),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: palette.border),
          ),
          child: Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: primary.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, size: 20, color: primary),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                          fontSize: 14.5, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      subtitle,
                      style: TextStyle(
                          fontSize: 11.5,
                          height: 1.45,
                          color: palette.textSecondary),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, size: 20, color: palette.textFaint),
            ],
          ),
        ),
      ),
    );
  }
}

class _CheckBanner extends StatelessWidget {
  const _CheckBanner({required this.text, this.showDot = true});

  final String text;
  final bool showDot;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 2),
      child: Row(
        children: [
          if (showDot) ...[
            const SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 8),
          ],
          Expanded(
            child: Text(
              text,
              style:
                  TextStyle(fontSize: 12, color: context.palette.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}

class _HealthChip extends StatelessWidget {
  const _HealthChip({required this.health, this.checking = false});

  final SourceHealth health;
  final bool checking;

  @override
  Widget build(BuildContext context) {
    if (checking) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: const Color(0x338FD6C8),
          borderRadius: BorderRadius.circular(5),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 9,
              height: 9,
              child: CircularProgressIndicator(
                strokeWidth: 1.6,
                color: const Color(0xFF8FD6C8).withValues(alpha: 0.9),
              ),
            ),
            const SizedBox(width: 4),
            const Text('检测中',
                style: TextStyle(fontSize: 10, color: Color(0xFF8FD6C8))),
          ],
        ),
      );
    }
    final Color color;
    switch (health.status) {
      case SourceHealthStatus.available:
        color = const Color(0xFF3DDC97);
        break;
      case SourceHealthStatus.unavailable:
        color = const Color(0xFFE86A6A);
        break;
      case SourceHealthStatus.unknown:
        color = context.palette.textFaint;
        break;
    }
    final latency = health.latencyLabel;
    final label = health.isUnknown || latency.isEmpty
        ? health.label
        : '${health.label} · $latency';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(label, style: TextStyle(fontSize: 10, color: color)),
    );
  }
}

class _SourceCard extends StatelessWidget {
  const _SourceCard({
    required this.source,
    required this.health,
    this.checking = false,
    required this.isCurrent,
    required this.onTap,
    required this.onCheck,
    required this.onToggle,
    required this.onCopy,
  });

  final CmsSource source;
  final SourceHealth health;
  final bool checking;
  final bool isCurrent;
  final VoidCallback onTap;
  final VoidCallback onCheck;
  final ValueChanged<bool> onToggle;

  /// 长按整张卡片才走这里：复制这个源的接口地址。
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    final unavailable = health.isUnavailable;
    return Material(
      color: context.palette.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: unavailable ? const Color(0x4DE86A6A) : context.palette.border,
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        onLongPress: onCopy,
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
                            style: const TextStyle(
                                fontSize: 15, fontWeight: FontWeight.w600),
                          ),
                        ),
                        const SizedBox(width: 8),
                        _HealthChip(health: health, checking: checking),
                        if (isCurrent) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: const Color(0x337FA6FF),
                              borderRadius: BorderRadius.circular(5),
                            ),
                            child: const Text(
                              '当前',
                              style: TextStyle(
                                  fontSize: 10, color: Color(0xFFAFC8FF)),
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
                      style: TextStyle(
                          fontSize: 11, color: context.palette.textFaint),
                    ),
                    if (unavailable && health.message.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        health.message,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 11, color: Color(0xFFE86A6A)),
                      ),
                    ] else if (source.note.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        source.note,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 11, color: context.palette.textSecondary),
                      ),
                    ],
                  ],
                ),
              ),
              IconButton(
                tooltip: checking ? '正在检测…' : '检测这个源',
                onPressed: checking ? null : onCheck,
                icon: Icon(
                  checking ? Icons.hourglass_top_rounded : Icons.network_check,
                  size: 19,
                  color: context.palette.textFaint,
                ),
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
