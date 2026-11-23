import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';

import '../core/constants.dart';
import '../core/hls_probe.dart';
import '../models/episode.dart';
import '../state/app_state.dart';
import '../theme/app_palette.dart';

/// 单页播放器：video_player（Android 侧 ExoPlayer），支持 HLS / 直链 / 倍速 / 连播 / 断点续播。
///
/// 换掉 libmpv 的原因：m3u8 里有广告段拼接（`#EXT-X-DISCONTINUITY`）时，
/// libmpv 往往播完广告段就停住、进度条也拖不动；ExoPlayer 对 HLS 的分段与
/// 拖动支持稳定得多，和 ZY-Player 用的是同一套内核。
class PlayerPage extends StatefulWidget {
  const PlayerPage({
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
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  VideoPlayerController? _controller;
  VoidCallback? _listener;

  AppState? _state;
  Timer? _hideTimer;
  Timer? _saveTimer;

  int _index = 0;
  double _rate = 1.0;
  bool _controlsVisible = true;
  bool _fullscreen = false;
  bool _dragging = false;
  double _dragValue = 0;
  bool _buffering = false;
  bool _completedOnce = false;
  String? _error;

  /// 换集 / 重开后自增，用来丢弃上一个控制器残留的异步回调。
  int _session = 0;

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex.clamp(0, widget.episodes.length - 1).toInt();
    _openCurrent(seekTo: widget.initialPosition);
    _scheduleHide();
    _saveTimer = Timer.periodic(const Duration(seconds: 5), (_) => _saveProgress());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _state ??= context.read<AppState>();
  }

  VideoPlayerValue get _value =>
      _controller?.value ?? const VideoPlayerValue(duration: Duration.zero);

  Duration get _position => _value.position;
  Duration get _duration => _value.duration;
  bool get _playing => _value.isPlaying;

  // ------------------------------------------------------------------ 播放

  Future<void> _openCurrent({Duration? seekTo}) async {
    final session = ++_session;
    final episode = widget.episodes[_index];
    await _releaseController();
    if (!mounted) return;

    setState(() {
      _error = null;
      _completedOnce = false;
      _buffering = true;
    });

    final controller = VideoPlayerController.networkUrl(
      Uri.parse(episode.url),
      httpHeaders: {
        'User-Agent': kPlayerUserAgent,
      },
    );
    _controller = controller;
    void listener() {
      if (!mounted || session != _session) return;
      final value = controller.value;
      if (value.isBuffering != _buffering) {
        setState(() => _buffering = value.isBuffering);
      } else {
        setState(() {});
      }
      if (value.isCompleted && !_completedOnce) {
        _completedOnce = true;
        _onCompleted();
      }
    }

    _listener = listener;
    controller.addListener(listener);

    try {
      await controller.initialize();
      if (!mounted || session != _session) return;
      await controller.setPlaybackSpeed(_rate);
      if (seekTo != null && seekTo > const Duration(seconds: 3)) {
        await controller.seekTo(seekTo);
      }
      await controller.play();
      if (!mounted || session != _session) return;
      setState(() => _buffering = false);

      if (seekTo == null) {
        // 有些源的 m3u8 把广告拼在正片前面，探测到就跳过去
        unawaited(_skipIntroAd(episode.url, session));
      }
    } catch (e) {
      if (!mounted || session != _session) return;
      setState(() {
        _error = _describe(e);
        _buffering = false;
      });
    }
  }

  Future<void> _releaseController() async {
    final old = _controller;
    final listener = _listener;
    _controller = null;
    _listener = null;
    if (old != null) {
      if (listener != null) old.removeListener(listener);
      try {
        await old.dispose();
      } catch (_) {}
    }
  }

  String _describe(Object error) {
    final text = error.toString();
    if (text.contains('403')) return '片源地址拒绝了请求（403），可能该源已失效或需要特定 UA';
    if (text.contains('404')) return '片源地址不存在（404）';
    return text.replaceFirst('Exception: ', '');
  }

  /// 探测并跳过片头广告（只处理 `#EXT-X-DISCONTINUITY` 拼接的广告段）。
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

    // 用户已经自己拖过进度，就别再插手了
    final current = _position;
    if (current > intro.adDuration + const Duration(seconds: 15)) return;

    try {
      await _controller?.seekTo(intro.adDuration + const Duration(milliseconds: 800));
    } catch (_) {
      return;
    }
    if (mounted && session == _session) {
      _toast('已跳过片头广告 ${intro.adDuration.inSeconds} 秒');
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 3),
        behavior: SnackBarBehavior.floating,
      ));
  }

  Future<void> _switchEpisode(int index) async {
    if (index < 0 || index >= widget.episodes.length || index == _index) return;
    await _saveProgress();
    if (!mounted) return;
    setState(() => _index = index);
    await _openCurrent();
    await _saveProgress();
  }

  void _onCompleted() {
    if (!mounted) return;
    final autoNext = _state?.autoPlayNext ?? true;
    if (autoNext && _index < widget.episodes.length - 1) {
      _switchEpisode(_index + 1);
    } else {
      _showControls();
    }
  }

  Future<void> _saveProgress() async {
    final state = _state;
    if (state == null || !state.rememberProgress) return;
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
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

  // ------------------------------------------------------------------ 控件

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 4), () {
      if (!mounted) return;
      setState(() => _controlsVisible = false);
    });
  }

  void _showControls() {
    if (!mounted) return;
    setState(() => _controlsVisible = true);
    _scheduleHide();
  }

  void _toggleControls() {
    if (_controlsVisible) {
      _hideTimer?.cancel();
      setState(() => _controlsVisible = false);
    } else {
      _showControls();
    }
  }

  Future<void> _seekBy(Duration delta) async {
    final controller = _controller;
    if (controller == null) return;
    final total = _duration;
    var target = _position + delta;
    if (target < Duration.zero) target = Duration.zero;
    if (total > Duration.zero && target > total) target = total;
    await controller.seekTo(target);
    _showControls();
  }

  Future<void> _seekTo(Duration target) async {
    final controller = _controller;
    if (controller == null) return;
    var value = target;
    if (value < Duration.zero) value = Duration.zero;
    if (_duration > Duration.zero && value > _duration) value = _duration;
    await controller.seekTo(value);
  }

  Future<void> _togglePlay() async {
    final controller = _controller;
    if (controller == null) return;
    if (controller.value.isPlaying) {
      await controller.pause();
    } else {
      if (controller.value.isCompleted) {
        await controller.seekTo(Duration.zero);
      }
      await controller.play();
    }
    _showControls();
  }

  Future<void> _toggleFullscreen() async {
    setState(() {
      _fullscreen = !_fullscreen;
      _controlsVisible = true;
    });
    _scheduleHide();
    if (_fullscreen) {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      await SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    } else {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      await SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.portraitUp,
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    }
  }

  void _showEpisodes() {
    _hideTimer?.cancel();
    setState(() => _controlsVisible = true);
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) {
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.55,
          minChildSize: 0.3,
          maxChildSize: 0.9,
          builder: (context, controller) {
            return Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 8, 8),
                  child: Row(
                    children: [
                      const Text('选集', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '${widget.groupName} · 共 ${widget.episodes.length} 集',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 12, color: context.palette.textFaint),
                        ),
                      ),
                      IconButton(
                        onPressed: () => Navigator.of(sheetContext).pop(),
                        icon: const Icon(Icons.close, size: 20),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: ListView.builder(
                    controller: controller,
                    itemCount: widget.episodes.length,
                    itemBuilder: (context, i) {
                      final episode = widget.episodes[i];
                      final selected = i == _index;
                      return ListTile(
                        selected: selected,
                        selectedTileColor: const Color(0x227FA6FF),
                        leading: selected
                            ? const Icon(Icons.play_arrow_rounded, size: 20)
                            : SizedBox(
                                width: 20,
                                child: Center(
                                  child: Text(
                                    '${i + 1}',
                                    style: TextStyle(fontSize: 12, color: context.palette.textFaint),
                                  ),
                                ),
                              ),
                        title: Text(
                          episode.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 14,
                            color: selected ? context.palette.textPrimary : context.palette.textSecondary,
                            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                          ),
                        ),
                        onTap: () {
                          Navigator.of(sheetContext).pop();
                          _switchEpisode(i);
                        },
                      );
                    },
                  ),
                ),
              ],
            );
          },
        );
      },
    ).whenComplete(_showControls);
  }

  @override
  void dispose() {
    _saveProgress();
    _hideTimer?.cancel();
    _saveTimer?.cancel();
    _session++;
    _releaseController();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    super.dispose();
  }

  // ------------------------------------------------------------------ 画面

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          _buildVideo(),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _toggleControls,
            onDoubleTapDown: (details) {
              final width = MediaQuery.of(context).size.width;
              final isLeft = details.localPosition.dx < width / 2;
              _seekBy(Duration(seconds: isLeft ? -10 : 10));
            },
          ),
          if (_buffering && _error == null)
            Center(
              child: SizedBox(
                width: 32,
                height: 32,
                child: CircularProgressIndicator(
                  strokeWidth: 2.4,
                  color: context.palette.textSecondary,
                ),
              ),
            ),
          if (_error != null) _buildErrorOverlay(),
          AnimatedOpacity(
            opacity: _controlsVisible ? 1 : 0,
            duration: const Duration(milliseconds: 220),
            child: IgnorePointer(
              ignoring: !_controlsVisible,
              child: _buildControls(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildVideo() {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      return const ColoredBox(color: Colors.black);
    }
    return Center(
      child: AspectRatio(
        aspectRatio: controller.value.aspectRatio <= 0 ? 16 / 9 : controller.value.aspectRatio,
        child: VideoPlayer(controller),
      ),
    );
  }

  Widget _buildErrorOverlay() {
    return Positioned.fill(
      child: ColoredBox(
        color: const Color(0xCC000000),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.error_outline_rounded, size: 44, color: context.palette.textSecondary),
                const SizedBox(height: 12),
                const Text('播放失败', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                Text(
                  _error!,
                  maxLines: 4,
                  textAlign: TextAlign.center,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, height: 1.5, color: context.palette.textSecondary),
                ),
                const SizedBox(height: 18),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    OutlinedButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('返回'),
                    ),
                    const SizedBox(width: 12),
                    FilledButton(
                      onPressed: () => _openCurrent(),
                      child: const Text('重试'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildControls() {
    return Stack(
      children: [
        Positioned(
          left: 0,
          right: 0,
          top: 0,
          child: Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0xCC000000), Colors.transparent],
              ),
            ),
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(4, 4, 12, 16),
                child: Row(
                  children: [
                    IconButton(
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20),
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            widget.vodName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '${widget.episodes[_index].name} · ${widget.groupName}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 11, color: context.palette.textSecondary),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: '选集',
                      onPressed: _showEpisodes,
                      icon: const Icon(Icons.playlist_play_rounded, size: 22),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.bottomCenter,
                end: Alignment.topCenter,
                colors: [Color(0xE6000000), Colors.transparent],
              ),
            ),
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 12, 8, 8),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildProgress(),
                    Row(
                      children: [
                        const SizedBox(width: 4),
                        IconButton(
                          onPressed: _index > 0 ? () => _switchEpisode(_index - 1) : null,
                          icon: const Icon(Icons.skip_previous_rounded, size: 22),
                          color: context.palette.textPrimary,
                          disabledColor: context.palette.textFaint,
                        ),
                        IconButton(
                          iconSize: 34,
                          color: context.palette.textPrimary,
                          onPressed: _togglePlay,
                          icon: Icon(
                            _playing ? Icons.pause_circle_filled_rounded : Icons.play_circle_fill_rounded,
                          ),
                        ),
                        IconButton(
                          onPressed: _index < widget.episodes.length - 1
                              ? () => _switchEpisode(_index + 1)
                              : null,
                          icon: const Icon(Icons.skip_next_rounded, size: 22),
                          color: context.palette.textPrimary,
                          disabledColor: context.palette.textFaint,
                        ),
                        const Spacer(),
                        PopupMenuButton<double>(
                          tooltip: '倍速',
                          initialValue: _rate,
                          onSelected: (value) async {
                            setState(() => _rate = value);
                            await _controller?.setPlaybackSpeed(value);
                            _showControls();
                          },
                          itemBuilder: (context) => const [
                            PopupMenuItem(value: 0.5, child: Text('0.5×')),
                            PopupMenuItem(value: 0.75, child: Text('0.75×')),
                            PopupMenuItem(value: 1.0, child: Text('1.0× 正常')),
                            PopupMenuItem(value: 1.25, child: Text('1.25×')),
                            PopupMenuItem(value: 1.5, child: Text('1.5×')),
                            PopupMenuItem(value: 2.0, child: Text('2.0×')),
                          ],
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                            child: Text(
                              '${_rate.toStringAsFixed(_rate == 1.0 ? 1 : 2)}×',
                              style: TextStyle(fontSize: 13, color: context.palette.textSecondary),
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: _fullscreen ? '退出全屏' : '全屏',
                          onPressed: _toggleFullscreen,
                          icon: Icon(
                            _fullscreen ? Icons.fullscreen_exit_rounded : Icons.fullscreen_rounded,
                            size: 24,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildProgress() {
    final duration = _duration;
    final maxMs = duration.inMilliseconds > 0 ? duration.inMilliseconds : 1;
    final currentMs = _dragging ? _dragValue : _position.inMilliseconds.toDouble();
    final value = currentMs.clamp(0.0, maxMs.toDouble()).toDouble();

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 2.4,
            activeTrackColor: const Color(0xFF7FA6FF),
            inactiveTrackColor: context.palette.textFaint,
            thumbColor: context.palette.textPrimary,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
          ),
          child: Slider(
            min: 0,
            max: maxMs.toDouble(),
            value: value,
            onChangeStart: (v) {
              _hideTimer?.cancel();
              setState(() {
                _dragging = true;
                _dragValue = v;
              });
            },
            onChanged: (v) => setState(() => _dragValue = v),
            onChangeEnd: (v) async {
              setState(() => _dragging = false);
              await _seekTo(Duration(milliseconds: v.round()));
              _showControls();
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Row(
            children: [
              Text(
                _formatDuration(_dragging ? Duration(milliseconds: _dragValue.round()) : _position),
                style: TextStyle(fontSize: 11, color: context.palette.textSecondary),
              ),
              const Spacer(),
              Text(
                duration.inMilliseconds > 0 ? _formatDuration(duration) : '--:--',
                style: TextStyle(fontSize: 11, color: context.palette.textSecondary),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

String _formatDuration(Duration value) {
  final hours = value.inHours;
  final minutes = value.inMinutes.remainder(60).toString().padLeft(2, '0');
  final seconds = value.inSeconds.remainder(60).toString().padLeft(2, '0');
  return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
}
