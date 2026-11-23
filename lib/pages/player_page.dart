import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:video_player/video_player.dart';
import 'package:volume_controller/volume_controller.dart';

import '../core/constants.dart';
import '../core/hls_probe.dart';
import '../core/pip.dart';
import '../core/play_resolver.dart';
import '../models/episode.dart';
import '../state/app_state.dart';
import '../theme/app_palette.dart';

/// 播放页配色：视频页恒为深色底，所以这里的文字/图标不跟随应用主题，
/// 统一用白系颜色，保证在暗画面上也看得清。
const Color _kText = Color(0xFFFFFFFF);
const Color _kTextDim = Color(0xE6FFFFFF);
const Color _kTextFaint = Color(0x99FFFFFF);
const Color _kAccent = Color(0xFF8FB6FF);

/// 单页播放器：video_player（Android 侧 ExoPlayer），支持 HLS / 直链 / 倍速 / 连播 / 断点续播。
///
/// 进入即沉浸式全屏（隐藏状态栏与导航栏），并按视频比例自动横/竖屏。
/// 手势：左右半屏上下滑调亮度 / 音量，双击播放暂停，双指上下滑调速。
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
  Timer? _hudTimer;

  final PlayResolver _resolver = PlayResolver();
  final VolumeController _volumeController = VolumeController.instance;

  int _index = 0;
  double _rate = 1.0;
  bool _controlsVisible = true;
  bool _dragging = false;
  double _dragValue = 0;
  bool _buffering = false;
  bool _completedOnce = false;
  String? _error;

  /// 换集 / 重开后自增，用来丢弃上一个控制器残留的异步回调。
  int _session = 0;

  // ---------------------------------------------------------------- 手势状态
  final Map<int, Offset> _pointerPositions = <int, Offset>{};
  bool get _twoFinger => _pointerPositions.length >= 2;
  double? _twoFingerLastY;
  double _speedAccum = 0;

  bool _gyrating = false;
  int _gestureSide = 0; // 0 无 / 1 亮度 / 2 音量
  double _gestureStartY = 0;
  double _gestureStartValue = 1;
  double _brightness = 1;
  double _volume = 1;

  IconData? _hudIcon;
  String? _hudText;
  double? _hudLevel;

  // ---------------------------------------------------------------- 画面比例
  double? _aspectOverride;
  String _aspectLabel = '自适应';

  // ---------------------------------------------------------------- 画中画
  bool _pipSupported = false;
  bool _inPip = false;

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex.clamp(0, widget.episodes.length - 1).toInt();
    _enterImmersive();
    _loadSystemLevels();
    _openCurrent(seekTo: widget.initialPosition);
    _scheduleHide();
    _saveTimer = Timer.periodic(const Duration(seconds: 5), (_) => _saveProgress());
    _setupPip();
  }

  Future<void> _setupPip() async {
    Pip.listen((inPip) {
      if (!mounted) return;
      setState(() {
        _inPip = inPip;
        if (inPip) _controlsVisible = false;
      });
      if (inPip) _hideTimer?.cancel();
    });
    final supported = await Pip.isSupported();
    if (!mounted) return;
    setState(() => _pipSupported = supported);
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

  // ------------------------------------------------------------------ 全屏

  Future<void> _enterImmersive() async {
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    await SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.portraitUp,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
  }

  Future<void> _applyOrientation(double aspectRatio) async {
    final landscape = aspectRatio >= 1.25;
    await SystemChrome.setPreferredOrientations(
      landscape
          ? const [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]
          : const [DeviceOrientation.portraitUp],
    );
  }

  Future<void> _loadSystemLevels() async {
    try {
      _brightness = (await ScreenBrightness.instance.application).clamp(0.0, 1.0);
    } catch (_) {}
    try {
      _volume = (await _volumeController.getVolume()).clamp(0.0, 1.0);
    } catch (_) {}
  }

  // ------------------------------------------------------------------ 播放

  Future<void> _openCurrent({Duration? seekTo, int attempt = 0}) async {
    final session = ++_session;
    final episode = widget.episodes[_index];
    final userAgent = attempt == 0 ? kPlayerUserAgent : kDefaultUserAgent;
    await _releaseController();
    if (!mounted) return;

    setState(() {
      _error = null;
      _completedOnce = false;
      _buffering = true;
    });

    // 网页播放页 → 抓页面里的 m3u8；直链 / m3u8 原样返回。
    var url = episode.url;
    try {
      url = await _resolver.resolve(episode.url, userAgent: userAgent);
    } catch (_) {
      url = episode.url;
    }
    if (!mounted || session != _session) return;
    final resolved = url;

    final controller = VideoPlayerController.networkUrl(
      Uri.parse(resolved),
      httpHeaders: {
        'User-Agent': userAgent,
        'Accept': '*/*',
      },
    );
    _controller = controller;
    void listener() {
      if (!mounted || session != _session) return;
      final value = controller.value;
      if (value.hasError && _error == null) {
        final message = _describe(value.errorDescription ?? '未知错误');
        setState(() {
          _error = message;
          _buffering = false;
        });
        return;
      }
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
      await _applyOrientation(controller.value.aspectRatio);

      if (seekTo == null) {
        // 有些源的 m3u8 把广告拼在正片前面，探测到就跳过去
        unawaited(_skipIntroAd(resolved, session));
      }
    } catch (e) {
      if (!mounted || session != _session) return;
      // 第一遍用手机 UA，失败后换成桌面 UA 再试一次（不少 CDN 只认桌面 UA）
      if (attempt < 1) {
        unawaited(Future<void>.delayed(const Duration(milliseconds: 300), () {
          if (mounted && session == _session) _openCurrent(seekTo: seekTo, attempt: attempt + 1);
        }));
        return;
      }
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
    if (text.contains('Source error')) {
      return '片源无法加载（Source error）：该线路可能失效，或地址不是真正的视频流。换个线路再试。';
    }
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

  // ------------------------------------------------------------------ 手势

  void _onPointerDown(PointerDownEvent event) {
    _pointerPositions[event.pointer] = event.localPosition;
    if (_twoFinger) {
      _twoFingerLastY = null;
      _speedAccum = 0;
      _gyrating = false;
    }
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (!_pointerPositions.containsKey(event.pointer)) return;
    _pointerPositions[event.pointer] = event.localPosition;
    if (!_twoFinger) return;

    final ys = _pointerPositions.values.map((o) => o.dy).toList();
    final average = ys.reduce((a, b) => a + b) / ys.length;
    final last = _twoFingerLastY;
    _twoFingerLastY = average;
    if (last == null) return;
    _speedAccum += average - last;
    while (_speedAccum.abs() >= 34) {
      final up = _speedAccum < 0;
      _speedAccum += up ? 34 : -34;
      _changeRate(up ? 0.25 : -0.25);
    }
  }

  void _onPointerUp(PointerEvent event) {
    _pointerPositions.remove(event.pointer);
    if (_pointerPositions.length < 2) {
      _twoFingerLastY = null;
      _speedAccum = 0;
    }
  }

  Future<void> _changeRate(double delta) async {
    final next = (_rate + delta).clamp(0.5, 3.0);
    if ((next - _rate).abs() < 0.001) return;
    setState(() => _rate = next);
    try {
      await _controller?.setPlaybackSpeed(next);
    } catch (_) {}
    _showHud(Icons.speed_rounded, '${next.toStringAsFixed(2)}× 倍速', null);
  }

  void _onVerticalDragStart(DragStartDetails details) {
    if (_twoFinger) return;
    final width = MediaQuery.of(context).size.width;
    _gestureSide = details.localPosition.dx < width / 2 ? 1 : 2;
    _gestureStartY = details.localPosition.dy;
    _gestureStartValue = _gestureSide == 1 ? _brightness : _volume;
    _gyrating = true;
    _hideTimer?.cancel();
    setState(() => _controlsVisible = true);
  }

  void _onVerticalDragUpdate(DragUpdateDetails details) {
    if (!_gyrating || _twoFinger) return;
    final height = math.max(MediaQuery.of(context).size.height, 1.0);
    final dy = (details.localPosition.dy - _gestureStartY) / height;
    final next = (_gestureStartValue - dy * 1.4).clamp(0.0, 1.0);
    if (_gestureSide == 1) {
      _brightness = next;
      unawaited(ScreenBrightness.instance.setApplicationScreenBrightness(next).catchError((_) {}));
      _showHud(Icons.brightness_6_rounded, '亮度 ${(next * 100).round()}%', next);
    } else if (_gestureSide == 2) {
      _volume = next;
      unawaited(_volumeController.setVolume(next).catchError((_) {}));
      _showHud(Icons.volume_up_rounded, '音量 ${(next * 100).round()}', next);
    }
  }

  void _onVerticalDragEnd(DragEndDetails details) {
    _gyrating = false;
    _gestureSide = 0;
    _scheduleHide();
  }

  void _showHud(IconData icon, String text, double? level) {
    setState(() {
      _hudIcon = icon;
      _hudText = text;
      _hudLevel = level;
    });
    _hudTimer?.cancel();
    _hudTimer = Timer(const Duration(milliseconds: 900), () {
      if (!mounted) return;
      setState(() {
        _hudIcon = null;
        _hudText = null;
        _hudLevel = null;
      });
    });
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
            // 选集弹窗跟随应用主题：深色模式用深底浅字，浅色模式用白底深字。
            final palette = context.palette;
            final scheme = Theme.of(context).colorScheme;
            return Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 8, 8),
                  child: Row(
                    children: [
                      Text(
                        '选集',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: palette.textPrimary,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '${widget.groupName} · 共 ${widget.episodes.length} 集',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 12, color: palette.textSecondary),
                        ),
                      ),
                      IconButton(
                        onPressed: () => Navigator.of(sheetContext).pop(),
                        icon: Icon(Icons.close, size: 20, color: palette.textSecondary),
                      ),
                    ],
                  ),
                ),
                Divider(height: 1, color: palette.border),
                Expanded(
                  child: ListView.builder(
                    controller: controller,
                    itemCount: widget.episodes.length,
                    itemBuilder: (context, i) {
                      final episode = widget.episodes[i];
                      final selected = i == _index;
                      return ListTile(
                        selected: selected,
                        selectedTileColor: scheme.primary.withValues(alpha: 0.14),
                        leading: selected
                            ? Icon(Icons.play_arrow_rounded, size: 20, color: scheme.primary)
                            : SizedBox(
                                width: 20,
                                child: Center(
                                  child: Text(
                                    '${i + 1}',
                                    style: TextStyle(fontSize: 12, color: palette.textFaint),
                                  ),
                                ),
                              ),
                        title: Text(
                          episode.name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 14,
                            color: selected ? scheme.primary : palette.textPrimary,
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

  // ------------------------------------------------------------ 视频比例

  static const List<(String, double?)> _aspectOptions = [
    ('自适应（按片源原始比例）', null),
    ('16 : 9（宽屏）', 16 / 9),
    ('16 : 10', 16 / 10),
    ('4 : 3', 4 / 3),
    ('21 : 9（超宽）', 21 / 9),
    ('2.35 : 1（影院）', 2.35),
    ('1 : 1（方形）', 1.0),
    ('9 : 16（竖屏）', 9 / 16),
    ('3 : 4（竖屏）', 3 / 4),
    ('9 : 21（手机竖屏）', 9 / 21),
  ];

  void _applyAspect(String label, double? ratio) {
    setState(() {
      _aspectOverride = ratio;
      _aspectLabel = label;
    });
    // 选竖屏比例（9:16、3:4）时把屏幕也转到竖屏，不然画面只是缩小一条、
    // 两边还留着大黑边；选宽屏比例则转回横屏。任何方向下都能选，不受当前方向限制。
    final natural = _value.aspectRatio > 0 ? _value.aspectRatio : 16 / 9;
    final effective = ratio ?? natural;
    _applyOrientation(effective);
  }

  /// 弹窗里的胶囊按钮：底色/文字全部跟随主题，浅色模式白底深字、深色模式深底浅字，
  /// 选中态用主题主色的低透明度填充，避免像之前那样白字压在浅灰底上。
  Widget _aspectChip(
    BuildContext context,
    String label,
    bool selected,
    VoidCallback onTap, {
    IconData? icon,
  }) {
    final palette = context.palette;
    final primary = Theme.of(context).colorScheme.primary;
    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.fromLTRB(icon == null ? 14 : 10, 9, 14, 9),
        decoration: BoxDecoration(
          color: selected ? primary.withValues(alpha: 0.20) : palette.surfaceHigh,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: selected ? primary : palette.border,
            width: selected ? 1.2 : 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 14, color: selected ? primary : palette.textSecondary),
              const SizedBox(width: 6),
            ],
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                height: 1.1,
                color: selected ? primary : palette.textPrimary,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 系统级画中画：整页缩成小窗，可以边看边干别的。
  Future<void> _enterPip() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      _toast('还没开始播放');
      return;
    }
    final natural = controller.value.aspectRatio;
    final ratio = _aspectOverride ?? (natural > 0 ? natural : 16 / 9);
    final ok = await Pip.enter(aspectRatio: ratio);
    if (!mounted) return;
    if (ok) {
      setState(() => _controlsVisible = false);
      _hideTimer?.cancel();
    } else {
      _toast('当前系统不支持画中画');
    }
  }

  void _showAspectSheet() {
    _hideTimer?.cancel();
    setState(() => _controlsVisible = true);
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) {
        final palette = sheetContext.palette;
        return Container(
          color: palette.surface,
          child: SafeArea(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(sheetContext).size.height * 0.7,
              ),
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.aspect_ratio_rounded,
                          size: 18,
                          color: palette.textSecondary,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '画面比例',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: palette.textPrimary,
                          ),
                        ),
                        const Spacer(),
                        Flexible(
                          child: Text(
                            _aspectLabel,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 12, color: palette.textFaint),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final option in _aspectOptions)
                          _aspectChip(
                            sheetContext,
                            option.$1,
                            _aspectLabel == option.$1,
                            () {
                              Navigator.of(sheetContext).pop();
                              _applyAspect(option.$1, option.$2);
                            },
                          ),
                        _aspectChip(
                          sheetContext,
                          '自定义比例…',
                          _aspectLabel.startsWith('自定义'),
                          () {
                            Navigator.of(sheetContext).pop();
                            _showCustomAspectDialog();
                          },
                          icon: Icons.edit_rounded,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    ).whenComplete(_showControls);
  }

  Future<void> _showCustomAspectDialog() async {
    // 不再预填 16 / 10：打开就是要用户自己填，空着更好输入
    final widthController = TextEditingController();
    final heightController = TextEditingController();
    final ratio = await showDialog<double>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('自定义画面比例'),
          content: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: widthController,
                  autofocus: true,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  textInputAction: TextInputAction.next,
                  decoration: const InputDecoration(
                    labelText: '宽',
                    hintText: '如 2.35',
                  ),
                ),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 12),
                child: Text('：'),
              ),
              Expanded(
                child: TextField(
                  controller: heightController,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  textInputAction: TextInputAction.done,
                  decoration: const InputDecoration(
                    labelText: '高',
                    hintText: '如 1',
                  ),
                  onSubmitted: (_) {
                    final w = double.tryParse(widthController.text.trim());
                    final h = double.tryParse(heightController.text.trim());
                    if (w == null || h == null || w <= 0 || h <= 0) {
                      Navigator.of(dialogContext).pop();
                      _toast('比例填写有误');
                      return;
                    }
                    Navigator.of(dialogContext).pop(w / h);
                  },
                ),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: const Text('取消')),
            FilledButton(
              onPressed: () {
                final w = double.tryParse(widthController.text.trim());
                final h = double.tryParse(heightController.text.trim());
                if (w == null || h == null || w <= 0 || h <= 0) {
                  Navigator.of(dialogContext).pop();
                  _toast('比例填写有误');
                  return;
                }
                Navigator.of(dialogContext).pop(w / h);
              },
              child: const Text('确定'),
            ),
          ],
        );
      },
    );
    if (ratio == null || !mounted) return;
    _applyAspect('自定义 ${ratio.toStringAsFixed(2)} : 1', ratio);
  }

  @override
  void dispose() {
    Pip.clearListener();
    _saveProgress();
    _hideTimer?.cancel();
    _saveTimer?.cancel();
    _hudTimer?.cancel();
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
          Listener(
            onPointerDown: _onPointerDown,
            onPointerMove: _onPointerMove,
            onPointerUp: _onPointerUp,
            onPointerCancel: _onPointerUp,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _toggleControls,
              onDoubleTap: _togglePlay,
              onVerticalDragStart: _onVerticalDragStart,
              onVerticalDragUpdate: _onVerticalDragUpdate,
              onVerticalDragEnd: _onVerticalDragEnd,
            ),
          ),
          if (_buffering && _error == null)
            Center(
              child: SizedBox(
                width: 32,
                height: 32,
                child: CircularProgressIndicator(strokeWidth: 2.4, color: _kTextFaint),
              ),
            ),
          if (_error != null) _buildErrorOverlay(),
          if (!_inPip) ...[
            _buildHud(),
            AnimatedOpacity(
              opacity: _controlsVisible ? 1 : 0,
              duration: const Duration(milliseconds: 220),
              child: IgnorePointer(
                ignoring: !_controlsVisible,
                child: _buildControls(),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildVideo() {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      return const ColoredBox(color: Colors.black);
    }
    final natural = controller.value.aspectRatio <= 0 ? 16 / 9 : controller.value.aspectRatio;
    return Center(
      child: AspectRatio(
        aspectRatio: _aspectOverride ?? natural,
        child: VideoPlayer(controller),
      ),
    );
  }

  Widget _buildHud() {
    final text = _hudText;
    final icon = _hudIcon;
    if (text == null || icon == null) return const SizedBox.shrink();
    final level = _hudLevel;
    return IgnorePointer(
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          decoration: BoxDecoration(
            color: const Color(0xE6151A24),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: const Color(0x33FFFFFF)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 26, color: _kText),
              const SizedBox(height: 6),
              Text(
                text,
                style: const TextStyle(fontSize: 13, color: _kText, fontWeight: FontWeight.w600),
              ),
              if (level != null) ...[
                const SizedBox(height: 8),
                SizedBox(
                  width: 120,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(
                      value: level,
                      minHeight: 4,
                      backgroundColor: const Color(0x33FFFFFF),
                      valueColor: const AlwaysStoppedAnimation<Color>(_kAccent),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildErrorOverlay() {
    return Positioned.fill(
      child: ColoredBox(
        color: const Color(0xD9000000),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline_rounded, size: 44, color: _kTextFaint),
                const SizedBox(height: 12),
                const Text('播放失败', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: _kText)),
                const SizedBox(height: 8),
                Text(
                  _error!,
                  maxLines: 4,
                  textAlign: TextAlign.center,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12, height: 1.5, color: _kTextDim),
                ),
                const SizedBox(height: 18),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    OutlinedButton(
                      onPressed: () => Navigator.of(context).pop(),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: _kText,
                        side: const BorderSide(color: Color(0x55FFFFFF)),
                      ),
                      child: const Text('返回'),
                    ),
                    const SizedBox(width: 12),
                    FilledButton(
                      onPressed: () => _openCurrent(),
                      style: FilledButton.styleFrom(
                        backgroundColor: _kAccent,
                        foregroundColor: Colors.black,
                      ),
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
                colors: [Color(0xE6000000), Colors.transparent],
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
                      icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 22, color: _kText),
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
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: _kText,
                              shadows: [Shadow(color: Colors.black54, blurRadius: 6)],
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '${widget.episodes[_index].name} · ${widget.groupName}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 11, color: _kTextDim),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: '选集',
                      onPressed: _showEpisodes,
                      icon: const Icon(Icons.playlist_play_rounded, size: 24, color: _kText),
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
                colors: [Color(0xF2000000), Colors.transparent],
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
                          icon: const Icon(Icons.skip_previous_rounded, size: 24),
                          color: _kText,
                          disabledColor: _kTextFaint,
                        ),
                        IconButton(
                          iconSize: 38,
                          color: _kText,
                          onPressed: _togglePlay,
                          icon: Icon(
                            _playing ? Icons.pause_circle_filled_rounded : Icons.play_circle_fill_rounded,
                          ),
                        ),
                        IconButton(
                          onPressed: _index < widget.episodes.length - 1
                              ? () => _switchEpisode(_index + 1)
                              : null,
                          icon: const Icon(Icons.skip_next_rounded, size: 24),
                          color: _kText,
                          disabledColor: _kTextFaint,
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
                            PopupMenuItem(value: 3.0, child: Text('3.0×')),
                          ],
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                            decoration: BoxDecoration(
                              color: const Color(0x26FFFFFF),
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: Text(
                              '${_rate.toStringAsFixed(_rate == 1.0 ? 1 : 2)}×',
                              style: const TextStyle(
                                fontSize: 12,
                                color: _kText,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: '画面比例：$_aspectLabel',
                          onPressed: _showAspectSheet,
                          icon: const Icon(Icons.aspect_ratio_rounded, size: 24, color: _kText),
                        ),
                        if (_pipSupported)
                          IconButton(
                            tooltip: '画中画',
                            onPressed: _enterPip,
                            icon: const Icon(
                              Icons.picture_in_picture_alt_rounded,
                              size: 24,
                              color: _kText,
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
            trackHeight: 3,
            activeTrackColor: _kAccent,
            inactiveTrackColor: const Color(0x4DFFFFFF),
            thumbColor: _kText,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
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
                style: const TextStyle(fontSize: 12, color: _kTextDim),
              ),
              const Spacer(),
              Text(
                duration.inMilliseconds > 0 ? _formatDuration(duration) : '--:--',
                style: const TextStyle(fontSize: 12, color: _kTextDim),
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
