import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:provider/provider.dart';

import '../core/hls_probe.dart';
import '../models/episode.dart';
import '../state/app_state.dart';
import '../theme/app_palette.dart';

/// 单页播放器：media_kit(libmpv) 内核，支持 HLS / 直链 / 倍速 / 连播 / 断点续播。
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
  late final Player _player;
  late final VideoController _videoController;

  final ValueNotifier<Duration> _position = ValueNotifier(Duration.zero);
  final ValueNotifier<Duration> _duration = ValueNotifier(Duration.zero);
  final ValueNotifier<bool> _playing = ValueNotifier(true);
  final ValueNotifier<bool> _buffering = ValueNotifier(false);
  final List<StreamSubscription> _subscriptions = [];

  AppState? _state;
  Timer? _hideTimer;
  Timer? _saveTimer;

  int _index = 0;
  double _rate = 1.0;
  bool _controlsVisible = true;
  bool _fullscreen = false;
  bool _dragging = false;
  double _dragValue = 0;
  String? _error;

  /// 中途被误判为播完（片头广告播完就停）时的自动续播次数。
  int _resumeAttempts = 0;
  int _resumeEpisodeIndex = -1;
  bool _introChecked = false;
  bool _seekingIntro = false;

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex.clamp(0, widget.episodes.length - 1).toInt();
    _player = Player();
    _videoController = VideoController(_player);
    _wireStreams();
    _openCurrent(seekTo: widget.initialPosition);
    _scheduleHide();
    _saveTimer = Timer.periodic(const Duration(seconds: 5), (_) => _saveProgress());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _state ??= context.read<AppState>();
  }

  void _wireStreams() {
    _subscriptions.add(_player.stream.position.listen((value) => _position.value = value));
    _subscriptions.add(_player.stream.duration.listen((value) => _duration.value = value));
    _subscriptions.add(_player.stream.playing.listen((value) => _playing.value = value));
    _subscriptions.add(_player.stream.buffering.listen((value) => _buffering.value = value));
    _subscriptions.add(_player.stream.error.listen((value) {
      if (!mounted) return;
      setState(() => _error = value);
    }));
    _subscriptions.add(_player.stream.completed.listen((value) {
      if (!value) return;
      _onCompleted();
    }));
  }

  Future<void> _openCurrent({Duration? seekTo}) async {
    final episode = widget.episodes[_index];
    if (_error != null && mounted) setState(() => _error = null);
    _position.value = Duration.zero;
    _duration.value = Duration.zero;
    _introChecked = false;
    _resumeAttempts = 0;
    _resumeEpisodeIndex = _index;
    try {
      await _player.open(Media(episode.url), play: true);
      await _player.setRate(_rate);
      if (seekTo != null && seekTo > const Duration(seconds: 3)) {
        await _player.seek(seekTo);
      } else {
        // 有些源的 m3u8 把广告拼在正片前面，直接跳过这一段
        unawaited(_skipIntroAd(episode.url));
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    }
  }

  /// 探测并跳过片头广告（只处理 `#EXT-X-DISCONTINUITY` 拼接的广告段）。
  Future<void> _skipIntroAd(String url) async {
    final state = _state;
    if (state == null || !state.skipIntroAd || _introChecked) return;
    _introChecked = true;
    HlsIntro? intro;
    try {
      intro = await probeHlsIntro(url, userAgent: state.userAgent);
    } catch (_) {
      return;
    }
    if (intro == null || !intro.worthSkipping) return;
    if (!mounted || _resumeEpisodeIndex != _index) return;

    // 用户已经自己拖过进度，就别再插手了
    final current = _player.state.position;
    if (current > intro.adDuration + const Duration(seconds: 15)) return;

    _seekingIntro = true;
    try {
      await _player.seek(intro.adDuration + const Duration(milliseconds: 800));
    } catch (_) {
      // 跳不过去就让广告播完，后面还有中途续播兜底
    } finally {
      _seekingIntro = false;
    }
    if (mounted) {
      _toast('已跳过片头广告 ${intro.adDuration.inSeconds} 秒');
    }
  }

  void _toast(String message) {
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
    if (!mounted || _seekingIntro) return;
    final position = _player.state.position;
    final duration = _player.state.duration;
    // 广告段拼接、切片断流时会「提前播完」：位置离总时长还很远就补一次续播，
    // 而不是直接当成一集结束跳到下一集。
    final midStream = _resumeEpisodeIndex == _index &&
        position > const Duration(seconds: 5) &&
        (duration <= Duration.zero || position < duration - const Duration(minutes: 1));
    if (midStream && _resumeAttempts < 2) {
      _resumeAttempts++;
      unawaited(_resumeAt(position + const Duration(seconds: 2)));
      return;
    }

    final autoNext = _state?.autoPlayNext ?? true;
    if (autoNext && _index < widget.episodes.length - 1) {
      _switchEpisode(_index + 1);
    } else {
      _showControls();
    }
  }

  Future<void> _resumeAt(Duration target) async {
    try {
      await _player.seek(target);
      await _player.play();
      if (mounted) _toast('播放中断，已自动从 ${_formatDuration(target)} 继续');
    } catch (_) {
      if (mounted) _toast('播放中断，续播失败');
    }
  }

  Future<void> _saveProgress() async {
    final state = _state;
    if (state == null || !state.rememberProgress) return;
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
      position: _player.state.position,
      duration: _player.state.duration,
    );
  }

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
    final max = _duration.value;
    var target = _position.value + delta;
    if (target < Duration.zero) target = Duration.zero;
    if (max > Duration.zero && target > max) target = max;
    await _player.seek(target);
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
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    _player.dispose();
    _position.dispose();
    _duration.dispose();
    _playing.dispose();
    _buffering.dispose();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          Video(
            controller: _videoController,
            controls: NoVideoControls,
            fit: BoxFit.contain,
          ),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _toggleControls,
            onDoubleTapDown: (details) {
              final width = MediaQuery.of(context).size.width;
              final isLeft = details.localPosition.dx < width / 2;
              _seekBy(Duration(seconds: isLeft ? -10 : 10));
            },
          ),
          ValueListenableBuilder<bool>(
            valueListenable: _buffering,
            builder: (context, buffering, child) {
              if (!buffering) return const SizedBox.shrink();
              return Center(
                child: SizedBox(
                  width: 32,
                  height: 32,
                  child: CircularProgressIndicator(strokeWidth: 2.4, color: context.palette.textSecondary),
                ),
              );
            },
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
                const SizedBox(height: 6),
                Text(
                  '提示：只支持 m3u8 / mp4 等直链，若返回的是网页地址需要在源侧解析。',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 11, color: context.palette.textFaint),
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
                      child: ValueListenableBuilder<Duration>(
                        valueListenable: _position,
                        builder: (context, position, child) {
                          return Column(
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
                          );
                        },
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
                        ValueListenableBuilder<bool>(
                          valueListenable: _playing,
                          builder: (context, playing, child) {
                            return IconButton(
                              iconSize: 34,
                              color: context.palette.textPrimary,
                              onPressed: () {
                                if (playing) {
                                  _player.pause();
                                } else {
                                  _player.play();
                                }
                                _showControls();
                              },
                              icon: Icon(
                                playing ? Icons.pause_circle_filled_rounded : Icons.play_circle_fill_rounded,
                              ),
                            );
                          },
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
                            await _player.setRate(value);
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
    return ValueListenableBuilder<Duration>(
      valueListenable: _position,
      builder: (context, position, child) {
        final duration = _duration.value;
        final maxMs = duration.inMilliseconds > 0 ? duration.inMilliseconds : 1;
        final currentMs = _dragging ? _dragValue : position.inMilliseconds.toDouble();
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
                onChangeStart: (v) => setState(() {
                  _dragging = true;
                  _dragValue = v;
                }),
                onChanged: (v) => setState(() => _dragValue = v),
                onChangeEnd: (v) async {
                  setState(() => _dragging = false);
                  await _player.seek(Duration(milliseconds: v.round()));
                  _showControls();
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Row(
                children: [
                  Text(
                    _formatDuration(_dragging ? Duration(milliseconds: _dragValue.round()) : position),
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
      },
    );
  }
}

String _formatDuration(Duration value) {
  final hours = value.inHours;
  final minutes = value.inMinutes.remainder(60).toString().padLeft(2, '0');
  final seconds = value.inSeconds.remainder(60).toString().padLeft(2, '0');
  return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
}
