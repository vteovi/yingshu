import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/lan_sync.dart';
import '../state/app_state.dart';
import '../theme/app_palette.dart';

/// 局域网设备同步。
///
/// 两种角色：
/// - 开启共享（发送端）：在 47820 端口起 HTTP 服务暴露选定数据，并周期组播广播自身；
///   另一端用「连接同步」自动发现或直接输入本机 IP 连接。
/// - 连接同步（接收端）：监听组播自动列出局域网内正在共享的设备，选设备 + 勾选类别
///   后拉取并合并到本地（只增不覆盖）。
class LanSyncPage extends StatefulWidget {
  const LanSyncPage({super.key});

  @override
  State<LanSyncPage> createState() => _LanSyncPageState();
}

class _LanSyncPageState extends State<LanSyncPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;

  // 共享端
  SyncServer? _server;
  Future<void> Function()? _stopAnnounce;
  bool _sharing = false;
  String _localIp = '';
  String _deviceName = '';
  final Set<String> _shareSelected = {
    SyncScope.sources,
    SyncScope.settings,
    SyncScope.favorites,
    SyncScope.history,
  };

  // 接收端
  LanListener? _listener;
  final List<LanDevice> _devices = <LanDevice>[];
  bool _refreshing = false;
  LanDevice? _selectedDevice;
  final TextEditingController _ipController = TextEditingController();
  final TextEditingController _portController =
      TextEditingController(text: '$kSyncHttpPort');
  final Set<String> _pullSelected = {
    SyncScope.sources,
    SyncScope.settings,
    SyncScope.favorites,
    SyncScope.history,
  };

  bool _syncing = false;
  String _syncResult = '';
  bool _cancelRequested = false;

  /// 同步阶段说明（连接中 / 正在接收 xx KB / 正在写入 N 条）。
  /// 「卡住不动」有一半是没有反馈造成的，所以每一步都要说出来。
  String _phase = '';
  double? _progress;
  DateTime _lastProgressAt = DateTime.fromMillisecondsSinceEpoch(0);

  bool _testing = false;
  String _testResult = '';
  bool _testOk = false;

  @override
  void initState() {
    super.initState();
    _deviceName = '影枢-${Random().nextInt(9000) + 1000}';
    _tabs = TabController(length: 2, vsync: this);
    _tabs.addListener(_onTabChanged);
    LanDiscovery.getLocalIp().then((ip) {
      if (mounted) setState(() => _localIp = ip ?? '');
    });
  }

  void _onTabChanged() {
    if (_tabs.index == 1) {
      _startListening();
    } else {
      _stopListening();
      if (mounted) setState(() => _devices.clear());
    }
  }

  @override
  void dispose() {
    _tabs.dispose();
    _stopSharing();
    _stopListening();
    _ipController.dispose();
    _portController.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------------ 共享端

  Future<void> _startSharing() async {
    if (_shareSelected.isEmpty) {
      _snack('请至少选择一类数据');
      return;
    }
    final app = context.read<AppState>();
    final scopes = Set<String>.from(_shareSelected);
    // 每次请求实时导出：开启共享之后新加的收藏、刚看完的记录也能同步出去
    final server = await SyncServer.start(
      () async => app.exportSyncData(scopes: scopes),
      port: kSyncHttpPort,
    );
    if (server == null) {
      _snack('共享端口 $kSyncHttpPort 被占用，请稍后重试');
      return;
    }
    final stopAnnounce = await LanDiscovery.startAnnouncing(server.port, _deviceName);
    if (!mounted) {
      await server.stop();
      return;
    }
    setState(() {
      _server = server;
      _stopAnnounce = stopAnnounce;
      _sharing = true;
    });
  }

  void _stopSharing() {
    _stopAnnounce?.call();
    _stopAnnounce = null;
    _server?.stop();
    _server = null;
    if (mounted) setState(() => _sharing = false);
  }

  // ------------------------------------------------------------------ 接收端

  Future<void> _startListening() async {
    if (_listener != null) return;
    final listener = await LanDiscovery.startListening((device) {
      if (!mounted) return;
      setState(() {
        final index = _devices.indexWhere((item) => item == device);
        if (index >= 0) {
          _devices[index] = device;
        } else {
          _devices.add(device);
        }
      });
    });
    if (mounted) setState(() => _listener = listener);
  }

  void _stopListening() {
    _listener?.stop();
    _listener = null;
  }

  /// 手动刷新：确保监听在跑，再发一次主动探测，让共享端立刻单播回应。
  Future<void> _refreshDevices() async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    if (_listener == null) await _startListening();
    _listener?.probe();
    await Future<void>.delayed(const Duration(milliseconds: 900));
    if (mounted) setState(() => _refreshing = false);
  }

  Future<void> _doSync() async {
    if (_pullSelected.isEmpty) {
      _snack('请至少选择一类数据');
      return;
    }
    final host = _ipController.text.trim();
    final port = int.tryParse(_portController.text.trim());
    if (host.isEmpty || port == null) {
      _snack('请输入对方的 IP 和端口');
      return;
    }
    setState(() {
      _syncing = true;
      _syncResult = '';
      _cancelRequested = false;
      _phase = '正在连接 $host:$port…';
      _progress = null;
    });
    try {
      final data = await SyncClient.fetch(
        host,
        port,
        onProgress: _pushReceiveProgress,
        isCancelled: () => _cancelRequested,
      );
      if (!mounted) return;

      // 只合并用户在接收端勾选的类别（对方可能共享了更多）
      final wanted = data.filtered(_pullSelected);
      final incoming = wanted.sources.length +
          wanted.favorites.length +
          wanted.history.length +
          (wanted.settings.isEmpty ? 0 : 1);
      setState(() {
        _phase = incoming == 0 ? '对方在勾选范围内没有数据' : '正在写入 $incoming 条…';
        _progress = null;
      });

      final app = context.read<AppState>();
      final summary = await app.mergeSyncData(
        wanted,
        onProgress: (scope, done, total) {
          if (!mounted || scope != SyncScope.sources) return;
          final now = DateTime.now();
          if (now.difference(_lastProgressAt).inMilliseconds < 80) return;
          _lastProgressAt = now;
          setState(() {
            _phase = '正在写入${_scopeLabel(scope)} $done/$total 条…';
            _progress = total <= 0 ? null : done / total;
          });
        },
        isCancelled: () => _cancelRequested,
      );
      if (!mounted) return;

      final cancelled = _cancelRequested;
      final parts = <String>[
        if (summary.sources > 0) '订阅源 ${summary.sources} 个',
        if (summary.favorites > 0) '收藏 ${summary.favorites} 条',
        if (summary.history > 0) '历史 ${summary.history} 条',
        if (summary.historyUpdated > 0) '播放进度 ${summary.historyUpdated} 条',
        if (summary.settings > 0) '设置 ${summary.settings} 项',
      ];
      setState(() {
        _progress = null;
        if (cancelled) {
          _syncResult = summary.total == 0
              ? '已取消，没有导入任何数据。'
              : '已停止导入：已写入 ${parts.join('、')}。\n剩下的没导入，再同步一次可以补齐。';
        } else {
          _syncResult = summary.total == 0
              ? '数据已是最新，没有需要补充的条目。'
              : '同步完成：${parts.join('、')}。';
        }
      });
      _snack(cancelled ? '已停止导入' : (summary.total == 0 ? '数据已是最新' : '同步完成'));
    } catch (error) {
      if (!mounted) return;
      if (error is SyncCancelled) {
        setState(() => _syncResult = '已取消同步，本地数据没有改动。');
      } else {
        setState(() => _syncResult = '同步失败：${SyncClient.describeError(error, host, port)}');
      }
    } finally {
      if (mounted) {
        setState(() {
          _syncing = false;
          _phase = '';
          _progress = null;
        });
      }
    }
  }

  void _pushReceiveProgress(int received) {
    final now = DateTime.now();
    if (now.difference(_lastProgressAt).inMilliseconds < 80) return;
    _lastProgressAt = now;
    if (!mounted) return;
    setState(() => _phase = '正在接收数据… ${_fmtBytes(received)}');
  }

  Future<void> _testConnection() async {
    final host = _ipController.text.trim();
    final port = int.tryParse(_portController.text.trim());
    if (host.isEmpty || port == null) {
      _snack('请输入对方的 IP 和端口');
      return;
    }
    setState(() {
      _testing = true;
      _testResult = '';
      _testOk = false;
    });
    try {
      final ms = await SyncClient.ping(host, port);
      if (!mounted) return;
      setState(() {
        _testOk = true;
        _testResult = '连接正常：$host:$port 可达（$ms ms），可以同步。';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _testOk = false;
        _testResult = SyncClient.describeError(error, host, port);
      });
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  static String _fmtBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  String _scopeLabel(String key) {
    for (final scope in SyncScope.all) {
      if (scope.key == key) return scope.label;
    }
    return key;
  }

  void _snack(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  // --------------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('设备同步'),
        bottom: TabBar(
          controller: _tabs,
          tabs: const [
            Tab(text: '开启共享'),
            Tab(text: '连接同步'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [_buildSharePane(), _buildPullPane()],
      ),
    );
  }

  Widget _buildScopeChips(Set<String> selected, void Function(String) toggle) {
    const icons = {
      SyncScope.sources: Icons.video_library_outlined,
      SyncScope.settings: Icons.settings_outlined,
      SyncScope.favorites: Icons.favorite_border,
      SyncScope.history: Icons.history,
    };
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: SyncScope.all.map((scope) {
        return FilterChip(
          selected: selected.contains(scope.key),
          avatar: Icon(icons[scope.key] ?? Icons.data_object, size: 18),
          label: Text(scope.label),
          onSelected: (_) => toggle(scope.key),
        );
      }).toList(),
    );
  }

  Widget _buildSharePane() {
    final palette = context.palette;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: [
        const Text('选择要共享的数据：', style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 10),
        _buildScopeChips(_shareSelected, (key) {
          setState(() {
            if (!_shareSelected.remove(key)) _shareSelected.add(key);
          });
        }),
        const SizedBox(height: 20),
        if (!_sharing) ...[
          FilledButton.icon(
            onPressed: _startSharing,
            icon: const Icon(Icons.wifi_tethering),
            label: const Text('开启共享'),
          ),
          const SizedBox(height: 12),
          Text(
            '开启后本机作为发送端，在局域网内广播自身。其他设备用「连接同步」'
            '可自动发现本机，也可以手动输入下方 IP 连接。',
            style: TextStyle(fontSize: 12, height: 1.6, color: palette.textSecondary),
          ),
        ] else ...[
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: palette.surfaceHigh,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFF3FBF8F), width: 0.8),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(
                  children: [
                    Icon(Icons.check_circle, color: Color(0xFF3FBF8F), size: 18),
                    SizedBox(width: 6),
                    Expanded(
                      child: Text('正在共享，等待其他设备连接…',
                          style: TextStyle(fontWeight: FontWeight.w600)),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text('本机名称：$_deviceName', style: const TextStyle(fontSize: 13)),
                Text('本机 IP：${_localIp.isEmpty ? '获取中…' : _localIp}',
                    style: const TextStyle(fontSize: 13)),
                Text('端口：${_server?.port ?? kSyncHttpPort}', style: const TextStyle(fontSize: 13)),
                const SizedBox(height: 8),
                Text(
                  '同步期间请让本机屏幕保持常亮。息屏后系统会冻结后台网络，'
                  '对方会一直等到超时才报错。',
                  style: TextStyle(fontSize: 11.5, height: 1.5, color: palette.textSecondary),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _stopSharing,
            icon: const Icon(Icons.stop),
            label: const Text('停止共享'),
          ),
        ],
      ],
    );
  }

  Widget _buildPullPane() {
    final palette = context.palette;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: [
        Row(
          children: [
            const Expanded(
              child: Text('局域网内发现的设备（点一下自动填入）：',
                  style: TextStyle(fontWeight: FontWeight.w600)),
            ),
            IconButton(
              tooltip: '刷新设备列表',
              onPressed: _refreshing ? null : _refreshDevices,
              icon: _refreshing
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh),
            ),
          ],
        ),
        const SizedBox(height: 6),
        if (_devices.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              '暂无发现。请确保对方已「开启共享」且两台设备在同一个 Wi‑Fi。',
              style: TextStyle(fontSize: 12, color: palette.textSecondary),
            ),
          )
        else
          ..._devices.map((device) {
            final selected = _selectedDevice == device;
            return ListTile(
              selected: selected,
              selectedTileColor: palette.surfaceHigh,
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.phone_android_outlined),
              title: Text(device.name),
              subtitle: Text('${device.ip} : ${device.httpPort}'),
              trailing: selected
                  ? const Icon(Icons.check_circle, color: Color(0xFF3FBF8F), size: 20)
                  : const Icon(Icons.arrow_forward_ios, size: 14),
              onTap: () => setState(() {
                _selectedDevice = device;
                _ipController.text = device.ip;
                _portController.text = '${device.httpPort}';
              }),
            );
          }),
        const SizedBox(height: 14),
        const Text('或直接输入对方 IP 和端口：', style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              flex: 3,
              child: TextField(
                controller: _ipController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'IP 地址', hintText: '192.168.1.20'),
                onChanged: (_) => setState(() => _selectedDevice = null),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              flex: 2,
              child: TextField(
                controller: _portController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: '端口'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 18),
        const Text('选择要同步的数据：', style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 10),
        _buildScopeChips(_pullSelected, (key) {
          setState(() {
            if (!_pullSelected.remove(key)) _pullSelected.add(key);
          });
        }),
        const SizedBox(height: 20),
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: _syncing ? null : _doSync,
                icon: _syncing
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.sync),
                label: Text(_syncing ? '同步中…' : '开始同步'),
              ),
            ),
            if (_syncing) ...[
              const SizedBox(width: 10),
              OutlinedButton(
                onPressed: _cancelRequested ? null : () => setState(() => _cancelRequested = true),
                child: Text(_cancelRequested ? '取消中…' : '取消'),
              ),
            ],
          ],
        ),
        if (_syncing && _phase.isNotEmpty) ...[
          const SizedBox(height: 12),
          Row(
            children: [
              Icon(Icons.hourglass_bottom, size: 14, color: palette.textSecondary),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  _phase,
                  style: TextStyle(fontSize: 12, color: palette.textSecondary),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              // 写库阶段有确切的 done/total，其它阶段用不确定进度条：
              // 「条还在动」本身就是没死机的证据。
              value: _progress,
              minHeight: 3,
            ),
          ),
        ],
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: (_syncing || _testing) ? null : _testConnection,
          icon: _testing
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.wifi_find),
          label: Text(_testing ? '测试中…' : '测试连接'),
        ),
        if (_testResult.isNotEmpty) ...[
          const SizedBox(height: 12),
          _ResultBox(text: _testResult, ok: _testOk),
        ],
        if (_syncResult.isNotEmpty) ...[
          const SizedBox(height: 12),
          _ResultBox(
            text: _syncResult,
            ok: _syncResult.startsWith('同步完成') || _syncResult.startsWith('数据已是最新'),
          ),
        ],
      ],
    );
  }
}

class _ResultBox extends StatelessWidget {
  const _ResultBox({required this.text, required this.ok});

  final String text;
  final bool ok;

  @override
  Widget build(BuildContext context) {
    final color = ok ? const Color(0xFF3FBF8F) : const Color(0xFFCF6679);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: context.palette.surfaceHigh,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.6), width: 0.8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(ok ? Icons.check_circle_outline : Icons.error_outline, size: 16, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(fontSize: 13, height: 1.5, color: context.palette.textPrimary),
            ),
          ),
        ],
      ),
    );
  }
}
