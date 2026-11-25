import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../core/lan_sync.dart';
import '../state/app_state.dart';
import '../theme/app_palette.dart';

/// 局域网设备同步：同一 Wi‑Fi 下把订阅源、收藏、历史合并到另一台设备。
///
/// 两台都能当主机；谁当主机谁先点「开始等待」，另一台填它的地址和配对码连接。
/// 合并规则是「只增不覆盖」，重复的条目直接跳过。
class LanSyncPage extends StatefulWidget {
  const LanSyncPage({super.key});

  @override
  State<LanSyncPage> createState() => _LanSyncPageState();
}

class _LanSyncPageState extends State<LanSyncPage> {
  final TextEditingController _addressController = TextEditingController();
  final TextEditingController _codeController = TextEditingController();

  LanSyncHost? _host;
  String? _hostAddress;
  String? _hostCode;
  String? _hostError;
  SyncMergeResult? _hostReceived;

  bool _connecting = false;
  String? _connectError;
  SyncMergeResult? _localResult;
  SyncMergeResult? _remoteResult;

  String? _localIp;

  @override
  void initState() {
    super.initState();
    lanSyncLocalAddress().then((ip) {
      if (mounted) setState(() => _localIp = ip);
    });
  }

  @override
  void dispose() {
    _host?.stop();
    _addressController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  Future<void> _startHost() async {
    final app = context.read<AppState>();
    setState(() {
      _hostError = null;
      _hostReceived = null;
    });
    try {
      final host = await LanSyncHost.start(
        snapshot: app.exportSyncData,
        onReceive: app.mergeSyncData,
      );
      host.received.future.then((result) async {
        await host.stop();
        if (!mounted) return;
        setState(() {
          _host = null;
          _hostReceived = result;
        });
      });
      if (!mounted) {
        await host.stop();
        return;
      }
      setState(() {
        _host = host;
        _hostAddress = host.address;
        _hostCode = host.code;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _hostError = '$error');
    }
  }

  Future<void> _stopHost() async {
    await _host?.stop();
    if (!mounted) return;
    setState(() => _host = null);
  }

  Future<void> _connect() async {
    final address = _addressController.text.trim();
    final code = _codeController.text.trim();
    if (address.isEmpty) {
      _snack('请填写主机的地址，例如 192.168.1.20');
      return;
    }
    if (code.isEmpty) {
      _snack('请填写主机上显示的配对码');
      return;
    }

    final app = context.read<AppState>();
    setState(() {
      _connecting = true;
      _connectError = null;
      _localResult = null;
      _remoteResult = null;
    });
    try {
      // 先拍一份自己的快照：合并之后再发出去会把两边都算重复
      final mine = app.exportSyncData();
      final theirs = await LanSyncClient.pull(address, code);
      final localMerged = await app.mergeSyncData(theirs);
      final remoteMerged = await LanSyncClient.push(address, code, mine);
      if (!mounted) return;
      setState(() {
        _localResult = localMerged;
        _remoteResult = remoteMerged;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _connectError = '$error');
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  void _snack(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final hosting = _host != null;

    return Scaffold(
      appBar: AppBar(title: const Text('局域网设备同步')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          Text(
            '两台设备连同一个 Wi‑Fi：一台点「开始等待」，另一台填它的地址和配对码连接。\n'
            '同步内容：订阅源、收藏、历史、设置。只做合并，不覆盖本机数据——'
            '重复的源/收藏/历史会跳过，设置只补本机还是默认值的项。',
            style: TextStyle(fontSize: 12, height: 1.7, color: palette.textSecondary),
          ),
          const SizedBox(height: 16),

          _SectionLabel('本机作为主机'),
          const SizedBox(height: 8),
          _Panel(
            children: [
              _InfoRow(
                label: '本机地址',
                value: _localIp == null ? '未检测到局域网地址' : '$_localIp (端口自动分配)',
              ),
              const SizedBox(height: 12),
              if (!hosting && _hostReceived == null)
                FilledButton.icon(
                  onPressed: _startHost,
                  icon: const Icon(Icons.wifi_tethering, size: 18),
                  label: const Text('开始等待另一台连接'),
                ),
              if (hosting) ...[
                _InfoRow(label: '主机地址', value: _hostAddress ?? '', selectable: true),
                const SizedBox(height: 10),
                _InfoRow(label: '配对码', value: _hostCode ?? '', big: true, selectable: true),
                const SizedBox(height: 12),
                Row(
                  children: [
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        '等待另一台设备连接并同步…',
                        style: TextStyle(fontSize: 12, color: palette.textSecondary),
                      ),
                    ),
                    TextButton(onPressed: _stopHost, child: const Text('停止')),
                  ],
                ),
              ],
              if (_hostReceived != null) ...[
                _ResultBox(
                  title: '已接收对方数据',
                  text: _hostReceived!.summary,
                  ok: true,
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: _startHost,
                  child: const Text('再同步一次'),
                ),
              ],
              if (_hostError != null) ...[
                const SizedBox(height: 8),
                _ResultBox(title: '启动失败', text: _hostError!, ok: false),
              ],
            ],
          ),

          const SizedBox(height: 20),
          _SectionLabel('连接另一台主机'),
          const SizedBox(height: 8),
          _Panel(
            children: [
              TextField(
                controller: _addressController,
                keyboardType: TextInputType.url,
                autocorrect: false,
                decoration: const InputDecoration(
                  labelText: '主机地址',
                  hintText: '192.168.1.20 或 192.168.1.20:47820',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _codeController,
                keyboardType: TextInputType.number,
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(6),
                ],
                decoration: const InputDecoration(
                  labelText: '配对码',
                  hintText: '主机上显示的 6 位数字',
                ),
              ),
              const SizedBox(height: 14),
              FilledButton.icon(
                onPressed: _connecting ? null : _connect,
                icon: _connecting
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.sync_rounded, size: 18),
                label: Text(_connecting ? '正在同步…' : '连接并同步'),
              ),
              if (_connectError != null) ...[
                const SizedBox(height: 12),
                _ResultBox(title: '同步失败', text: _connectError!, ok: false),
              ],
              if (_localResult != null) ...[
                const SizedBox(height: 12),
                _ResultBox(
                  title: '本机新增',
                  text: _localResult!.total == 0 ? '没有新的数据，两台已经一致' : _localResult!.summary,
                  ok: true,
                ),
                const SizedBox(height: 8),
                _ResultBox(
                  title: '对方新增',
                  text: _remoteResult == null
                      ? '已断开，对方可能已经停止等待'
                      : (_remoteResult!.total == 0
                          ? '对方没有新增数据'
                          : _remoteResult!.summary),
                  ok: _remoteResult != null,
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        color: context.palette.textSecondary,
      ),
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: context.palette.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: context.palette.border, width: 0.8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.label,
    required this.value,
    this.big = false,
    this.selectable = false,
  });

  final String label;
  final String value;
  final bool big;
  final bool selectable;

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      fontSize: big ? 20 : 13,
      fontWeight: big ? FontWeight.w700 : FontWeight.w500,
      letterSpacing: big ? 3 : 0,
      color: context.palette.textPrimary,
    );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        SizedBox(
          width: 74,
          child: Text(
            label,
            style: TextStyle(fontSize: 12, color: context.palette.textFaint),
          ),
        ),
        Expanded(
          child: selectable
              ? SelectableText(value, style: style)
              : Text(value, style: style),
        ),
      ],
    );
  }
}

class _ResultBox extends StatelessWidget {
  const _ResultBox({required this.title, required this.text, required this.ok});

  final String title;
  final String text;
  final bool ok;

  @override
  Widget build(BuildContext context) {
    final color = ok ? const Color(0xFF3FBF8F) : const Color(0xFFCF6679);
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: context.palette.surfaceHigh,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.6), width: 0.8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: color),
          ),
          const SizedBox(height: 4),
          Text(
            text,
            style: TextStyle(fontSize: 12, height: 1.5, color: context.palette.textSecondary),
          ),
        ],
      ),
    );
  }
}
