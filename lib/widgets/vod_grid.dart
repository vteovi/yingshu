import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/image_cache.dart';
import '../core/image_util.dart';
import '../data/cms_api.dart';
import '../models/cms_source.dart';
import '../models/vod.dart';
import '../state/app_state.dart';
import '../theme/app_palette.dart';
import 'state_views.dart';
import 'vod_card.dart';
import '../pages/detail_page.dart';

const double _horizontalPadding = 16.0;
const double _spacing = 12.0;

/// 大屏时把目标宽度按比例放大，让「小 / 中 / 大」在平板上也是三档真实差异。
///
/// 手机（< 600dp）按基准值；小平板放大 1.15 倍；大屏放大 1.35 倍。
double _wideScale(double maxWidth) {
  if (maxWidth >= 1000) return 1.35;
  if (maxWidth >= 700) return 1.2;
  if (maxWidth >= 600) return 1.1;
  return 1.0;
}

/// 每张竖版海报的目标宽度（单位 dp），按海报大小分档。
///
/// 三档的间距收窄过：原来是 104 / 158 / 232，手机上「大」会直接铺满整屏，
/// 和小档差得太远；现在 104 / 142 / 186，差距更均匀。
double _targetTileWidth(PosterSize size, double maxWidth) {
  final base = switch (size) {
    PosterSize.small => 104.0,
    PosterSize.medium => 142.0,
    PosterSize.large => 186.0,
  };
  return base * _wideScale(maxWidth);
}

/// 一套网格的落位参数：几列、每格多宽、每格多高。
class VodGridSpec {
  const VodGridSpec({required this.columns, required this.width, required this.extent});

  final int columns;
  final double width;
  final double extent;
}

/// 计算当前宽高/档位/排布下的网格规格。
///
/// 竖版只有一列时（「大」档）不再让海报铺满整屏，而是限宽居中，
/// 否则三档尺寸差得离谱、看起来也不规整。
VodGridSpec vodGridSpec({
  required double maxWidth,
  required PosterSize size,
  required bool landscape,
}) {
  const double caption = 46;
  final available = maxWidth - _horizontalPadding * 2;

  final portraitColumns = (available / _targetTileWidth(size, maxWidth)).floor().clamp(1, 10);
  final portraitWidth = (available - _spacing * (portraitColumns - 1)) / portraitColumns;

  if (!landscape) {
    // 列数由目标宽度取整决定，但单列/列数相同时还要限一下宽度：
    // 否则某些屏宽下「中」和「大」会算出同样的列和同样的宽度，看起来像没生效。
    var width = portraitWidth;
    final cap = _targetTileWidth(size, maxWidth) * 1.18;
    if (width > cap) width = cap;
    return VodGridSpec(
      columns: portraitColumns,
      width: width,
      extent: width * 1.5 + caption,
    );
  }

  // 横版：按档位给一个「目标宽度」，再由可用宽度反推列数。
  // 不能像以前那样只按一屏密度挑列数——手机上「中」「大」都会落到 1 列，
  // 宽度被可用宽度吃满，两档看起来就一模一样了。
  final landscapeTarget = switch (size) {
    PosterSize.small => 128.0,
    PosterSize.medium => 200.0,
    PosterSize.large => 300.0,
  } * _wideScale(maxWidth);
  final columns = (available / landscapeTarget).floor().clamp(1, 4);
  var width = (available - _spacing * (columns - 1)) / columns;
  if (columns == 1) {
    // 单列限宽，避免「中」和「大」都变成整屏宽度
    final cap = landscapeTarget * 1.35;
    if (width > cap) width = cap;
  }
  return VodGridSpec(
    columns: columns,
    width: width,
    extent: width / (16 / 10) + 44,
  );
}

/// 竖版网格：2:3 海报，列数随宽度与海报大小自适应。
SliverGridDelegate _portraitDelegate(double maxWidth, PosterSize size) {
  final spec = vodGridSpec(maxWidth: maxWidth, size: size, landscape: false);
  return SliverGridDelegateWithFixedCrossAxisCount(
    crossAxisCount: spec.columns,
    mainAxisSpacing: 16,
    crossAxisSpacing: _spacing,
    mainAxisExtent: spec.extent,
  );
}

/// 横版网格：16:10 封面 + 图下一行文字，列数按一屏条目密度挑。
SliverGridDelegate _landscapeDelegate(double maxWidth, PosterSize size) {
  final spec = vodGridSpec(maxWidth: maxWidth, size: size, landscape: true);
  return SliverGridDelegateWithFixedCrossAxisCount(
    crossAxisCount: spec.columns,
    mainAxisSpacing: 16,
    crossAxisSpacing: _spacing,
    mainAxisExtent: spec.extent,
  );
}

/// 把卡片放进网格格子里。单列限宽时用它在格子内水平居中。
class VodCell extends StatelessWidget {
  const VodCell({super.key, required this.width, required this.child});

  final double width;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topCenter,
      child: SizedBox(width: width, child: child),
    );
  }
}

/// 按当前设置选网格代理。收藏 / 历史页复用同一套，保证三处排版一致。
SliverGridDelegate vodGridDelegate({
  required double maxWidth,
  required PosterSize size,
  required bool landscape,
}) {
  return landscape ? _landscapeDelegate(maxWidth, size) : _portraitDelegate(maxWidth, size);
}

SliverGridDelegate _delegateFor(double maxWidth, PosterSize size, bool landscape) =>
    vodGridDelegate(maxWidth: maxWidth, size: size, landscape: landscape);

/// 海报原始宽高比（宽 ÷ 高）缓存。
///
/// 「原始比例」模式要让每张卡按图片自身比例排，所以先量出比例再排版。
/// 量不出来（图还没下载完）时先按 2:3 占位，量到后自动重排一次。
class PosterRatioStore extends ChangeNotifier {
  PosterRatioStore._();

  static final PosterRatioStore instance = PosterRatioStore._();

  final Map<String, double> _ratios = {};

  double? ratioOf(String url) => _ratios[url];

  void put(String url, double ratio) {
    if (ratio <= 0 || !ratio.isFinite) return;
    final old = _ratios[url];
    if (old != null && (old - ratio).abs() < 0.02) return;
    _ratios[url] = ratio;
    notifyListeners();
  }
}

/// 解析一次图片尺寸，把宽高比写进 [PosterRatioStore]。
void _probePosterRatio(BuildContext context, String url, String? api) {
  if (url.isEmpty || PosterRatioStore.instance.ratioOf(url) != null) return;
  final provider = CachedNetworkImageProvider(
    url,
    cacheManager: PosterCacheManager.instance,
    headers: imageHeadersFor(api),
    maxWidth: 480,
  );
  final stream = provider.resolve(createLocalImageConfiguration(context));
  late ImageStreamListener listener;
  listener = ImageStreamListener(
    (info, _) {
      PosterRatioStore.instance.put(url, info.image.width / info.image.height);
      stream.removeListener(listener);
    },
    onError: (_, __) => stream.removeListener(listener),
  );
  stream.addListener(listener);
}

/// 「原始比例」模式的瀑布流：图片不裁切，按自身宽高比决定卡片高度，
/// 逐张填进当前最矮的一列，于是行与行之间错落不齐。
class _MasonryGrid extends StatelessWidget {
  const _MasonryGrid({
    required this.videos,
    required this.source,
    required this.size,
    required this.maxWidth,
    required this.landscape,
  });

  final List<VodItem> videos;
  final CmsSource source;
  final PosterSize size;
  final double maxWidth;
  final bool landscape;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: PosterRatioStore.instance,
      builder: (context, _) {
        final available = maxWidth - _horizontalPadding * 2;
        final target = _targetTileWidth(size, maxWidth);
        final columns = (available / target).floor().clamp(1, 8);
        final itemWidth = (available - _spacing * (columns - 1)) / columns;

        final heights = List<double>.filled(columns, 0);
        final placements = <_Placement>[];
        for (final vod in videos) {
          final url = normalizeImageUrl(vod.pic, api: source.api);
          final ratio = PosterRatioStore.instance.ratioOf(url) ??
              (landscape ? 16 / 10 : 2 / 3);
          final caption = landscape ? 52.0 : 46.0;
          final height = itemWidth / ratio + caption;
          var column = 0;
          for (var i = 1; i < columns; i++) {
            if (heights[i] < heights[column]) column = i;
          }
          placements.add(_Placement(
            vod: vod,
            left: column * (itemWidth + _spacing),
            top: heights[column],
            width: itemWidth,
            height: height,
          ));
          heights[column] += height + 16;
        }
        final total = heights.reduce((a, b) => a > b ? a : b);

        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!context.mounted) return;
          for (final vod in videos) {
            final url = normalizeImageUrl(vod.pic, api: source.api);
            _probePosterRatio(context, url, source.api);
          }
        });

        return Padding(
          padding: const EdgeInsets.fromLTRB(
            _horizontalPadding,
            10,
            _horizontalPadding,
            0,
          ),
          child: SizedBox(
            height: total,
            child: Stack(
              children: [
                for (final p in placements)
                  Positioned(
                    left: p.left,
                    top: p.top,
                    width: p.width,
                    height: p.height,
                    child: VodCard(
                      vod: p.vod,
                      apiBase: source.api,
                      landscape: landscape,
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => DetailPage(
                            source: source,
                            vodId: p.vod.vodId,
                            initialName: p.vod.name,
                            initialPic: p.vod.pic,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _Placement {
  _Placement({
    required this.vod,
    required this.left,
    required this.top,
    required this.width,
    required this.height,
  });

  final VodItem vod;
  final double left;
  final double top;
  final double width;
  final double height;
}

/// 首屏固定列表：首页「推荐」用。
class VodGridView extends StatelessWidget {
  const VodGridView({
    super.key,
    required this.videos,
    required this.source,
    this.onRefresh,
    this.footerText,
  });

  final List<VodItem> videos;
  final CmsSource source;
  final Future<void> Function()? onRefresh;
  final String? footerText;

  @override
  Widget build(BuildContext context) {
    // 在 build 期取一次设置：LayoutBuilder 里再读 Provider 会触发布局期注册依赖的断言
    final posterSize = context.select<AppState, PosterSize>((s) => s.posterSize);
    final landscape = context.select<AppState, bool>((s) => s.useLandscapeCard);
    final layout = context.select<AppState, PosterLayout>((s) => s.posterLayout);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!context.mounted) return;
      precachePosters(context, videos.map((v) => v.pic), api: source.api);
    });

    final content = LayoutBuilder(
      builder: (context, constraints) {
        final spec = vodGridSpec(
          maxWidth: constraints.maxWidth,
          size: posterSize,
          landscape: landscape,
        );
        final footer = SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(_horizontalPadding, 8, _horizontalPadding, 24),
            child: Text(
              footerText ?? '最近更新 ${videos.length} 部 · 下拉刷新',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: context.palette.textFaint),
            ),
          ),
        );

        if (layout == PosterLayout.actual) {
          return CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              SliverToBoxAdapter(
                child: _MasonryGrid(
                  videos: videos,
                  source: source,
                  size: posterSize,
                  maxWidth: constraints.maxWidth,
                  landscape: landscape,
                ),
              ),
              footer,
            ],
          );
        }

        return CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(_horizontalPadding, 10, _horizontalPadding, 4),
              sliver: SliverGrid(
                gridDelegate: _delegateFor(constraints.maxWidth, posterSize, landscape),
                delegate: SliverChildBuilderDelegate(
                  (context, i) {
                    final vod = videos[i];
                    return VodCell(
                      width: spec.width,
                      child: VodCard(
                        vod: vod,
                        apiBase: source.api,
                        landscape: landscape,
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => DetailPage(
                              source: source,
                              vodId: vod.vodId,
                              initialName: vod.name,
                              initialPic: vod.pic,
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                  childCount: videos.length,
                ),
              ),
            ),
            footer,
          ],
        );
      },
    );

    if (onRefresh == null) return content;
    return RefreshIndicator(onRefresh: onRefresh!, child: content);
  }
}

/// 分类分页列表：首屏加载 + 滚动到底自动翻页。
class VodPagedGrid extends StatefulWidget {
  const VodPagedGrid({
    super.key,
    required this.source,
    required this.typeId,
    this.autoLoad = true,
  });

  final CmsSource source;
  final String typeId;

  /// 只有当前标签可见时才加载，避免一次打开十几个分类的请求。
  final bool autoLoad;

  @override
  State<VodPagedGrid> createState() => _VodPagedGridState();
}

class _VodPagedGridState extends State<VodPagedGrid>
    with AutomaticKeepAliveClientMixin {
  final ScrollController _controller = ScrollController();
  final List<VodItem> _items = [];

  /// 标签滑出屏幕后不要销毁，回来时海报和列表都在，不会重新转圈。
  @override
  bool get wantKeepAlive => true;

  int _page = 0;
  int _pageCount = 1;
  bool _loading = false;
  bool _hasMore = true;
  bool _firstLoaded = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onScroll);
    if (widget.autoLoad) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _loadMore());
    }
  }

  void _onScroll() {
    if (!_controller.hasClients) return;
    if (_controller.position.pixels >= _controller.position.maxScrollExtent - 500) {
      _loadMore();
    }
  }

  Future<void> _loadMore() async {
    if (_loading || !_hasMore) return;
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final result = await context.read<AppState>().api.fetchList(
            widget.source,
            typeId: widget.typeId,
            page: _page + 1,
          );
      if (!mounted) return;
      setState(() {
        _page = result.page > 0 ? result.page : _page + 1;
        _pageCount = result.pageCount > 0 ? result.pageCount : 1;
        _items.addAll(result.videos);
        _hasMore = _page < _pageCount && result.videos.isNotEmpty;
        _firstLoaded = true;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error is CmsException ? error.message : '$error';
        _hasMore = false;
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _retry() {
    setState(() {
      _error = null;
      _hasMore = true;
    });
    _loadMore();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final posterSize = context.select<AppState, PosterSize>((s) => s.posterSize);
    final landscape = context.select<AppState, bool>((s) => s.useLandscapeCard);
    final layout = context.select<AppState, PosterLayout>((s) => s.posterLayout);

    if (_items.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        precachePosters(context, _items.map((v) => v.pic), api: widget.source.api);
      });
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        if (_items.isEmpty) {
          if (_error != null) {
            return ErrorView(message: _error!, onRetry: _retry);
          }
          if (!_firstLoaded) return const LoadingView(text: '正在加载分类…');
          return const EmptyView(title: '这个分类还没有内容', icon: Icons.inbox_outlined);
        }

        final spec = vodGridSpec(
          maxWidth: constraints.maxWidth,
          size: posterSize,
          landscape: landscape,
        );

        return CustomScrollView(
          controller: _controller,
          slivers: [
            if (layout == PosterLayout.actual)
              SliverToBoxAdapter(
                child: _MasonryGrid(
                  videos: _items,
                  source: widget.source,
                  size: posterSize,
                  maxWidth: constraints.maxWidth,
                  landscape: landscape,
                ),
              )
            else
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(_horizontalPadding, 12, _horizontalPadding, 8),
                sliver: SliverGrid(
                  gridDelegate: _delegateFor(constraints.maxWidth, posterSize, landscape),
                  delegate: SliverChildBuilderDelegate(
                    (context, i) {
                      final vod = _items[i];
                      return VodCell(
                        width: spec.width,
                        child: VodCard(
                          vod: vod,
                          apiBase: widget.source.api,
                          landscape: landscape,
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => DetailPage(
                                source: widget.source,
                                vodId: vod.vodId,
                                initialName: vod.name,
                                initialPic: vod.pic,
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                    childCount: _items.length,
                  ),
                ),
              ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 28),
                child: Center(child: _footer(context)),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _footer(BuildContext context) {
    if (_loading) {
      return const SizedBox(
        width: 22,
        height: 22,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }
    if (_error != null) {
      return TextButton.icon(
        onPressed: _retry,
        icon: const Icon(Icons.refresh, size: 16),
        label: Text('加载失败，点击重试（$_error）', maxLines: 2),
      );
    }
    if (!_hasMore) {
      return Text(
        '共 ${_items.length} 部 · 已经到底了',
        style: TextStyle(fontSize: 12, color: context.palette.textFaint),
      );
    }
    return const SizedBox(height: 12);
  }
}
