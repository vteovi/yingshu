import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../core/clip_url.dart';
import '../core/constants.dart';
import '../models/cms_source.dart';
import '../state/app_state.dart';
import '../theme/app_palette.dart';

/// 新增 / 编辑单个订阅源，保存前可以先做一次连通性探测。
class SourceEditPage extends StatefulWidget {
  const SourceEditPage({super.key, this.source});

  final CmsSource? source;

  @override
  State<SourceEditPage> createState() => _SourceEditPageState();
}

class _SourceEditPageState extends State<SourceEditPage> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController;
  late final TextEditingController _apiController;
  late final TextEditingController _noteController;

  late bool _enabled;
  bool _testing = false;
  bool? _testOk;
  String? _testResult;
  bool _clipFilled = false;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.source?.name ?? '');
    _apiController = TextEditingController(text: widget.source?.api ?? '');
    _noteController = TextEditingController(text: widget.source?.note ?? '');
    _enabled = widget.source?.enabled ?? true;
    // 只是新建时才预填，编辑已有源不要把手里的地址冲掉
    if (widget.source == null) _prefillFromClipboard();
  }

  /// 新建源时把剪贴板里的接口地址捞过来，省得用户来回切应用复制粘贴。
  /// 只有剪贴板里确实是个 http(s) 地址才填，别的文字一概不动。
  Future<void> _prefillFromClipboard() async {
    if (_apiController.text.trim().isNotEmpty) return;
    String? raw;
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      raw = data?.text;
    } catch (_) {
      return; // 桌面端剪贴板不可用时静默跳过
    }
    final candidate = findUrlInText(raw);
    if (candidate == null || !mounted) return;
    setState(() {
      _apiController.text = candidate;
      _apiController.selection = TextSelection.collapsed(
        offset: candidate.length,
      );
      _clipFilled = true;
    });
  }

  @override
  void dispose() {
    _nameController.dispose();
    _apiController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  Future<void> _test() async {
    final api = _apiController.text.trim();
    final uri = Uri.tryParse(api);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      setState(() {
        _testOk = false;
        _testResult = '请先填写合法接口地址';
      });
      return;
    }
    setState(() {
      _testing = true;
      _testResult = null;
      _testOk = null;
    });
    try {
      final index = await context.read<AppState>().api.probe(api);
      if (!mounted) return;
      setState(() {
        _testOk = true;
        _testResult =
            '连接成功：${index.categories.length} 个分类，返回 ${index.videos.length} 条最新数据';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _testOk = false;
        _testResult = '连接失败：$error';
      });
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    FocusScope.of(context).unfocus();

    final app = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final api = _apiController.text.trim();
    final name = _nameController.text.trim().isEmpty
        ? (Uri.tryParse(api)?.host ?? '未命名源')
        : _nameController.text.trim();
    final note = _noteController.text.trim();

    try {
      if (widget.source == null) {
        await app.addSource(CmsSource(
          id: CmsSource.newSourceId(),
          name: name,
          api: api,
          enabled: _enabled,
          note: note,
        ));
        navigator.pop();
        messenger.showSnackBar(const SnackBar(content: Text('已添加订阅源')));
      } else {
        await app.updateSource(widget.source!.copyWith(
          name: name,
          api: api,
          enabled: _enabled,
          note: note,
        ));
        navigator.pop();
        messenger.showSnackBar(const SnackBar(content: Text('已保存修改')));
      }
    } catch (error) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('保存失败：$error')));
    }
  }

  /// 编辑已有源时才能删：确认后连它的收藏/历史一起清理，然后退回列表。
  Future<void> _delete() async {
    final source = widget.source;
    if (source == null) return;
    final app = context.read<AppState>();
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);

    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除订阅源'),
        content: Text('确定删除「${source.name}」吗？\n与它关联的收藏和观看记录也会一并清理。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('删除')),
        ],
      ),
    );
    if (ok != true) return;

    await app.removeSource(source.id);
    navigator.pop();
    final cleaned = app.lastRemovedSourceCleanup;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(cleaned > 0 ? '已删除，同时清理了 $cleaned 条收藏/历史记录' : '已删除'),
      ));
  }

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.source != null;
    return Scaffold(
      appBar: AppBar(title: Text(isEdit ? '编辑订阅源' : '添加订阅源')),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
          children: [
            Text(
              '苹果CMS v10 采集接口地址，一般形如：\nhttps://你的域名/api.php/provide/vod/',
              style: TextStyle(
                  fontSize: 12,
                  height: 1.6,
                  color: context.palette.textSecondary),
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _apiController,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: '采集接口地址 *',
                hintText: kApiHint,
              ),
              validator: (value) {
                final text = (value ?? '').trim();
                if (text.isEmpty) return '请填写采集接口地址';
                final uri = Uri.tryParse(text);
                if (uri == null ||
                    !(uri.scheme == 'http' || uri.scheme == 'https') ||
                    uri.host.isEmpty) {
                  return '请填写以 http:// 或 https:// 开头的完整地址';
                }
                return null;
              },
            ),
            if (_clipFilled)
              Padding(
                padding: const EdgeInsets.only(top: 8, left: 4),
                child: Row(
                  children: [
                    Icon(
                      Icons.content_paste_rounded,
                      size: 14,
                      color: context.palette.textSecondary,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '地址已从剪贴板填入，可直接点「测试」验一下',
                        style: TextStyle(
                          fontSize: 12,
                          color: context.palette.textSecondary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 14),
            TextFormField(
              controller: _nameController,
              decoration: const InputDecoration(
                labelText: '显示名称',
                hintText: '不填则自动使用域名',
              ),
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: _noteController,
              decoration: const InputDecoration(
                labelText: '备注',
                hintText: '例如：备用源 / 更新快',
              ),
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('启用此源'),
              subtitle: Text(
                '停用后不参与首页与聚合搜索',
                style:
                    TextStyle(fontSize: 12, color: context.palette.textFaint),
              ),
              value: _enabled,
              onChanged: (value) => setState(() => _enabled = value),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _testing ? null : _test,
                    icon: _testing
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.wifi_tethering, size: 18),
                    label: Text(_testing ? '正在测试…' : '测试连接'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _save,
                    icon: const Icon(Icons.save_outlined, size: 18),
                    label: Text(isEdit ? '保存修改' : '添加'),
                  ),
                ),
              ],
            ),
            if (_testResult != null) ...[
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: context.palette.surface,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: (_testOk ?? false)
                        ? const Color(0xFF3FBF8F)
                        : const Color(0xFFCF6679),
                    width: 0.8,
                  ),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      (_testOk ?? false)
                          ? Icons.check_circle_outline
                          : Icons.error_outline,
                      size: 18,
                      color: (_testOk ?? false)
                          ? const Color(0xFF3FBF8F)
                          : const Color(0xFFCF6679),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _testResult!,
                        style: TextStyle(
                            fontSize: 12,
                            height: 1.5,
                            color: context.palette.textSecondary),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            if (isEdit) ...[
              const SizedBox(height: 24),
              const Divider(height: 1),
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: _delete,
                icon: const Icon(Icons.delete_outline, size: 18),
                label: const Text('删除这个订阅源'),
                style: TextButton.styleFrom(
                    foregroundColor: const Color(0xFFE86A6A)),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
