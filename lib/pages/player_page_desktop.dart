import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:provider/provider.dart';

import '../core/constants.dart';
import '../core/hls_probe.dart';
import '../core/play_resolver.dart';
import '../models/episode.dart';
import '../state/app_state.dart';

/// 桌面端（Windows / Linux / macOS）是否走 media_kit 播放器。
///
/// 手机端的 `video_player` 只有 Android / iOS 的原生实现，桌面端拿到的是
/// 空实现：控制器永远 initialize 不成功，表现就是「点播放一直转圈 / 黑屏」。
/// 所以桌面统一换成 media_kit（libmpv 内核），HLS / mp4 / flv 都能放。
bool get useDesktopPlayer =>
    defaultTargetPlatform == TargetPlatform.windows ||
    defaultTargetPlatform == TargetPlatform.linux ||
    defaultTargetPlatform == TargetPlatform.macOS;

const Color _kText = Color(0xFFFFFFFF);
const Color _kTextDim = Color(0xE6FFFFFF);
const Color _kTextFaint = Color(0x99FFFFFF);
const Color _kAccent = Color(0xFF8FB6FF);

/// 桌面播放页：鼠标 + 键盘操作，不涉及亮度/音量手势、屏幕旋转、画中画这些手机特性。
///
/// 快捷键：空格 播放/暂停，← → 快退/快进 10 秒，↑ ↓ 音量，F 全窗口，
/// Esc 关闭选集面板（不退出播放）。
class DesktopPlayerPage extends StatefulWidget {
  const DesktopPlayerPage({
    super.key,
    required this.sourceId,
    required this.sourceName,
    required this.vodId,
    required this.vodName,
    this.vodPic = '',
    required this.groupName,
    required this.episodes,
    required this.initialIndex,
    this.initialPosition,
  });

  final String sourceId;
  final String sourceName;
  final String vodId;
  final String vodName;
  final String vodPic;
  final String groupName;
  final List<Episode> episodes;
  final int initialIndex;
  final Duration? initialPosition;

  @override
  State<DesktopPlayerPage> createState() => _DesktopPlayerPageState();
}

class _DesktopPlayerPageState extends State<DesktopPlayerPage> {
  late final Player _player = Player();
  late final VideoController _video = VideoController(_player);

  final PlayResolver _resolver = PlayResolver();
  final List<StreamSubscription<dynamic>> _subs = [];

  AppState? _state;
  int _index = 0;
  int _session = 0;

  double _rate = 1.0;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _playing = false;
  bool _buffering = false;
  bool _loading = true;
  bool _completed = false;
  String? _error;

  bool _controlsVisible = true;
  Timer? _hideTimer;
  Timer? _saveTimer;

  bool _dragging = false;
  double _dragMs = 0;

  bool _episodePanel = false;

  @override
  void initState() {
    super.initState();
    _state = context.read<AppState>();
    _index = widget.initialIndex.clamp(0, widget.episodes.length - 1).toInt();
    _bindStreams();
    _openCurrent(seekTo: widget.initialPosition);
    _saveTimer =
        Timer.periodic(const Duration(seconds: 5), (_) => _saveProgress());
    _scheduleHideControls();
  }

  void _bindStreams() {
    _subs.add(_player.stream.position.listen((value) {
      if (!mounted || _dragging) return;
      setState(() => _position = value);
    }));
    _subs.add(_player.stream.duration.listen((value) {
      if (!mounted) return;
      setState(() => _duration = value);
    }));
    _subs.add(_player.stream.playing.listen((value) {
      if (!mounted) return;
      setState(() => _playing = value);
      if (value) _scheduleHideControls();
    }));
    _subs.add(_player.stream.buffering.listen((value) {
      if (!mounted) return;
      setState(() => _buffering = value);
    }));
    _subs.add(_player.stream.completed.listen((value) {
      if (!mounted || !value) return;
      setState(() => _completed = true);
      _onCompleted();
    }));
    _subs.add(_player.stream.error.listen((message) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = message.isEmpty ? '播放失败（内核没有给出原因）' : message;
      });
    }));
  }

  Future<void> _openCurrent({Duration? seekTo}) async {
    final session = ++_session;
    setState(() {
      _loading = true;
      _error = null;
      _completed = false;
      _position = Duration.zero;
      _duration = Duration.zero;
    });

    final episode = widget.episodes[_index];
    final userAgent = _state?.userAgent ?? '';
    var url = episode.url;
    try {
      url = await _resolver.resolve(episode.url, userAgent: userAgent);
    } catch (_) {
      url = episode.url; // 解析失败就用原始地址，让内核自己试
    }
    if (!mounted || session != _session) return;

    try {
      await _player.open(
        Media(url,
            httpHeaders: userAgent.isEmpty ? null : {'User-Agent': userAgent}),
      );
      if (session != _session) return;
      await _player.setRate(_rate);
      setState(() => _loading = false);

      if (seekTo != null && seekTo > Duration.zero) {
        // 刚 open 时时长还没到，直接 seek 会被内核丢掉，等一下再定位
        await _waitDuration();
        if (session != _session) return;
        await _player.seek(seekTo);
      } else {
        unawaited(_skipIntroAd(url, session));
      }
    } catch (error) {
      if (!mounted || session != _session) return;
      setState(() {
        _loading = false;
        _error = '打开失败：$error';
      });
    }
  }

  /// 等到内核报出时长（最多等 8 秒），用于「恢复上次进度」时定位。
  Future<void> _waitDuration() async {
    if (_duration > Duration.zero) return;
    final completer = Completer<void>();
    late final StreamSubscription<Duration> sub;
    sub = _player.stream.duration.listen((value) {
      if (value > Duration.zero && !completer.isCompleted) completer.complete();
    });
    final timeout = Timer(const Duration(seconds: 8), () {
      if (!completer.isCompleted) completer.complete();
    });
    try {
      await completer.future;
    } finally {
      timeout.cancel();
      await sub.cancel();
    }
  }

  /// 和手机端一致：探测 `#EXT-X-DISCONTINUITY` 拼接的片头广告并跳过。
  Future<void> _skipIntroAd(String url, int session) async {
    final state = _state;
    if (state == null || !state.skipIntroAd) return;
    HlsIntro? intro;
    try {
      intro = await probeHlsIntro(url, userAgent: kPlayerUserAgent);
    } catch (_) {
      return;
    }
    if (intro == null || !intro.worthSkipping) return;
    if (!mounted || session != _session) return;
    try {
      await _player.seek(intro.adDuration + const Duration(milliseconds: 800));
    } catch (_) {}
  }

  void _onCompleted() {
    final auto = _state?.autoPlayNext ?? false;
    if (auto && _index < widget.episodes.length - 1) {
      _switchEpisode(_index + 1);
      return;
    }
    _showControls();
  }

  Future<void> _switchEpisode(int index) async {
    if (index < 0 || index >= widget.episodes.length || index == _index) return;
    await _saveProgress();
    setState(() => _index = index);
    _episodePanel = false;
    await _openCurrent();
  }

  Future<void> _saveProgress() async {
    final state = _state;
    if (state == null || !state.rememberProgress) return;
    if (_duration <= Duration.zero && _position <= Duration.zero) return;
    final episode = widget.episodes[_index];
    await state.saveProgress(
      sourceId: widget.sourceId,
      sourceName: widget.sourceName,
      vodId: widget.vodId,
      vodName: widget.vodName,
      vodPic: widget.vodPic,
      groupName: widget.groupName,
      episodeName: episode.name,
      episodeUrl: episode.url,
      episodeIndex: _index,
      position: _position,
      duration: _duration,
    );
  }

  // ---------------------------------------------------------------- 界面状态

  void _scheduleHideControls() {
    _hideTimer?.cancel();
    if (!_playing) return;
    _hideTimer = Timer(const Duration(seconds: 4), () {
      if (mounted && _playing && !_episodePanel) {
        setState(() => _controlsVisible = false);
      }
    });
  }

  void _showControls() {
    if (!_controlsVisible) setState(() => _controlsVisible = true);
    _scheduleHideControls();
  }

  void _togglePlay() {
    if (_completed) {
      _player.seek(Duration.zero);
      _player.play();
      setState(() => _completed = false);
      return;
    }
    if (_playing) {
      _player.pause();
    } else {
      _player.play();
    }
    _showControls();
  }

  Future<void> _seekTo(double ms) async {
    final target = Duration(milliseconds: ms.round());
    if (target < Duration.zero) return;
    if (target > _duration) return;
    await _player.seek(target);
    if (mounted) setState(() => _position = target);
  }

  Future<void> _setRate(double rate) async {
    setState(() => _rate = rate);
    await _player.setRate(rate);
    _showControls();
  }

  void _nudge(int seconds) {
    final target = _position + Duration(seconds: seconds);
    _seekTo(target.inMilliseconds.toDouble());
  }

  String _fmt(Duration d) {
    final total = d.inSeconds;
    final h = total ~/ 3600;
    final m = (total % 3600) ~/ 60;
    final s = total % 60;
    final mm = m.toString().padLeft(2, '0');
    final ss = s.toString().padLeft(2, '0');
    return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
  }

  @override
  void dispose() {
    _saveProgress();
    _hideTimer?.cancel();
    _saveTimer?.cancel();
    for (final sub in _subs) {
      sub.cancel();
    }
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Focus(
        autofocus: true,
        onKeyEvent: (node, event) {
          if (event is! KeyDownEvent) return KeyEventResult.ignored;
          switch (event.logicalKey) {
            case LogicalKeyboardKey.space:
              _togglePlay();
              return KeyEventResult.handled;
            case LogicalKeyboardKey.arrowLeft:
              _nudge(-10);
              return KeyEventResult.handled;
            case LogicalKeyboardKey.arrowRight:
              _nudge(10);
              return KeyEventResult.handled;
            case LogicalKeyboardKey.arrowUp:
              _player.setVolume((_player.state.volume + 5).clamp(0, 100));
              return KeyEventResult.handled;
            case LogicalKeyboardKey.arrowDown:
              _player.setVolume((_player.state.volume - 5).clamp(0, 100));
              return KeyEventResult.handled;
            case LogicalKeyboardKey.escape:
              if (_episodePanel) {
                setState(() => _episodePanel = false);
                return KeyEventResult.handled;
              }
              return KeyEventResult.ignored;
          }
          return KeyEventResult.ignored;
        },
        child: MouseRegion(
          onHover: (_) => _showControls(),
          child: Stack(
            fit: StackFit.expand,
            children: [
              Center(
                child: Video(
                  controller: _video,
                  controls: NoVideoControls,
                  fit: BoxFit.contain,
                ),
              ),
              if (_loading) const Center(child: CircularProgressIndicator()),
              if (_buffering && !_loading)
                const Positioned(
                  right: 20,
                  top: 20,
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              if (_error != null) _buildError(),
              AnimatedOpacity(
                opacity: _controlsVisible || _episodePanel ? 1 : 0,
                duration: const Duration(milliseconds: 180),
                child: IgnorePointer(
                  ignoring: !(_controlsVisible || _episodePanel),
                  child: _buildChrome(),
                ),
              ),
              if (_episodePanel) _buildEpisodePanel(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildError() {
    return Container(
      color: Colors.black54,
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline_rounded, color: _kTextFaint, size: 42),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 48),
            child: Text(
              _error!,
              textAlign: TextAlign.center,
              style:
                  const TextStyle(color: _kTextDim, fontSize: 13, height: 1.6),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              OutlinedButton(
                onPressed: () => _openCurrent(),
                child: const Text('重试'),
              ),
              const SizedBox(width: 12),
              TextButton(
                onPressed: () => Navigator.of(context).maybePop(),
                child: const Text('返回'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildChrome() {
    return Column(
      children: [
        // 顶部：返回 + 标题 + 选集
        Container(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 20),
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0xCC000000), Color(0x00000000)],
            ),
          ),
          child: Row(
            children: [
              IconButton(
                onPressed: () => Navigator.of(context).maybePop(),
                icon: const Icon(Icons.arrow_back_rounded, color: _kText),
                tooltip: '返回',
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      widget.vodName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: _kText,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${widget.episodes[_index].name} · ${widget.groupName}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: _kTextFaint, fontSize: 12),
                    ),
                  ],
                ),
              ),
              TextButton.icon(
                onPressed: () => setState(() => _episodePanel = !_episodePanel),
                icon: const Icon(Icons.playlist_play_rounded,
                    color: _kTextDim, size: 18),
                label: const Text('选集',
                    style: TextStyle(color: _kTextDim, fontSize: 12)),
              ),
            ],
          ),
        ),
        const Spacer(),
        // 底部：进度条 + 控制按钮
        Container(
          padding: const EdgeInsets.fromLTRB(16, 24, 16, 14),
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.bottomCenter,
              end: Alignment.topCenter,
              colors: [Color(0xCC000000), Color(0x00000000)],
            ),
          ),
          child: Column(
            children: [
              Row(
                children: [
                  Text(
                      _fmt(_dragging
                          ? Duration(milliseconds: _dragMs.round())
                          : _position),
                      style: const TextStyle(color: _kTextDim, fontSize: 12)),
                  Expanded(
                    child: SliderTheme(
                      data: SliderThemeData(
                        trackHeight: 3,
                        thumbShape:
                            const RoundSliderThumbShape(enabledThumbRadius: 6),
                        overlayShape:
                            const RoundSliderOverlayShape(overlayRadius: 14),
                      ),
                      child: Slider(
                        value: (_dragging
                                ? _dragMs
                                : _position.inMilliseconds.toDouble())
                            .clamp(
                                0,
                                _duration.inMilliseconds
                                    .toDouble()
                                    .clamp(1, double.infinity)),
                        max: _duration.inMilliseconds
                            .toDouble()
                            .clamp(1, double.infinity),
                        onChanged: (value) => setState(() {
                          _dragging = true;
                          _dragMs = value;
                        }),
                        onChangeEnd: (value) {
                          setState(() => _dragging = false);
                          _seekTo(value);
                        },
                      ),
                    ),
                  ),
                  Text(_fmt(_duration),
                      style: const TextStyle(color: _kTextDim, fontSize: 12)),
                ],
              ),
              const SizedBox(height: 4),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    onPressed:
                        _index > 0 ? () => _switchEpisode(_index - 1) : null,
                    icon: const Icon(Icons.skip_previous_rounded,
                        color: _kTextDim),
                    tooltip: '上一集',
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    iconSize: 44,
                    onPressed: _togglePlay,
                    icon: Icon(
                      _completed
                          ? Icons.replay_rounded
                          : (_playing
                              ? Icons.pause_rounded
                              : Icons.play_arrow_rounded),
                      color: _kText,
                    ),
                    tooltip: _playing ? '暂停（空格）' : '播放（空格）',
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    onPressed: _index < widget.episodes.length - 1
                        ? () => _switchEpisode(_index + 1)
                        : null,
                    icon: const Icon(Icons.skip_next_rounded, color: _kTextDim),
                    tooltip: '下一集',
                  ),
                  const SizedBox(width: 16),
                  PopupMenuButton<double>(
                    tooltip: '倍速',
                    initialValue: _rate,
                    onSelected: _setRate,
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 0.5, child: Text('0.5x')),
                      PopupMenuItem(value: 0.75, child: Text('0.75x')),
                      PopupMenuItem(value: 1.0, child: Text('1.0x')),
                      PopupMenuItem(value: 1.25, child: Text('1.25x')),
                      PopupMenuItem(value: 1.5, child: Text('1.5x')),
                      PopupMenuItem(value: 2.0, child: Text('2.0x')),
                      PopupMenuItem(value: 2.5, child: Text('2.5x')),
                      PopupMenuItem(value: 3.0, child: Text('3.0x')),
                    ],
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 6),
                      child: Text(
                        '${_rate.toStringAsFixed(_rate == _rate.roundToDouble() ? 0 : 2)}x',
                        style: const TextStyle(color: _kAccent, fontSize: 13),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    onPressed: () =>
                        setState(() => _episodePanel = !_episodePanel),
                    icon: const Icon(Icons.list_rounded,
                        color: _kTextDim, size: 20),
                    tooltip: '选集',
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildEpisodePanel() {
    return Positioned(
      right: 0,
      top: 0,
      bottom: 0,
      child: Container(
        width: 300,
        color: const Color(0xF7111115),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 8, 6),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '${widget.groupName} · 共 ${widget.episodes.length} 集',
                      style: const TextStyle(
                          color: _kText,
                          fontSize: 13,
                          fontWeight: FontWeight.w600),
                    ),
                  ),
                  IconButton(
                    onPressed: () => setState(() => _episodePanel = false),
                    icon: const Icon(Icons.close_rounded,
                        color: _kTextFaint, size: 18),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.only(bottom: 16),
                itemCount: widget.episodes.length,
                itemBuilder: (context, i) {
                  final active = i == _index;
                  return ListTile(
                    dense: true,
                    onTap: () => _switchEpisode(i),
                    title: Text(
                      widget.episodes[i].name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        color: active ? _kAccent : _kTextDim,
                        fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                      ),
                    ),
                    trailing: active
                        ? const Icon(Icons.volume_up_rounded,
                            size: 16, color: _kAccent)
                        : null,
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
