import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

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

/// 每张竖版海报的目标宽度（单位 dp），按海报大小分档。
///
/// 列数是「可用宽度 ÷ 目标宽度」取整，所以同一个档位在手机上列少、在平板上列多。
double _targetTileWidth(PosterSize size) {
  switch (size) {
    case PosterSize.small:
      return 104;
    case PosterSize.medium:
      return 158;
    case PosterSize.large:
      return 232;
  }
}

/// 竖版网格：2:3 海报，列数随宽度与海报大小自适应。
SliverGridDelegate _portraitDelegate(double maxWidth, PosterSize size) {
  final available = maxWidth - _horizontalPadding * 2;
  final target = _targetTileWidth(size);
  final columns = (available / target).floor().clamp(1, 8);
  final itemWidth = (available - _spacing * (columns - 1)) / columns;
  final itemHeight = itemWidth * 1.5 + 44;
  return SliverGridDelegateWithFixedCrossAxisCount(
    crossAxisCount: columns,
    mainAxisSpacing: 16,
    crossAxisSpacing: _spacing,
    mainAxisExtent: itemHeight,
  );
}

/// 横版网格：16:10 封面 + 下方两行文字，单卡上限 420 宽（超宽就多排一列）。
SliverGridDelegate _landscapeDelegate(double maxWidth, PosterSize size) {
  const double maxExtent = 420;
  const double caption = 50;
  final available = maxWidth - _horizontalPadding * 2;
  final columns = (available / maxExtent).ceil().clamp(1, 6);
  final tileWidth = available / columns;
  final coverHeight = tileWidth / (16 / 10);
  final cardHeight = coverHeight + caption;
  return SliverGridDelegateWithMaxCrossAxisExtent(
    maxCrossAxisExtent: tileWidth,
    childAspectRatio: tileWidth / cardHeight,
    mainAxisSpacing: 16,
    crossAxisSpacing: _spacing,
  );
}

/// 按当前设置选网格代理。
SliverGridDelegate _delegateFor(double maxWidth, PosterSize size, bool landscape) {
  return landscape ? _landscapeDelegate(maxWidth, size) : _portraitDelegate(maxWidth, size);
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
    final landscape = context.select<AppState, bool>((s) => s.landscapeCard);

    final content = LayoutBuilder(
      builder: (context, constraints) {
        final delegate = _delegateFor(constraints.maxWidth, posterSize, landscape);

        return CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(_horizontalPadding, 10, _horizontalPadding, 4),
              sliver: SliverGrid(
                gridDelegate: delegate,
                delegate: SliverChildBuilderDelegate(
                  (context, i) {
                    final vod = videos[i];
                    return VodCard(
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
                    );
                  },
                  childCount: videos.length,
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(_horizontalPadding, 8, _horizontalPadding, 24),
                child: Text(
                  footerText ?? '最近更新 ${videos.length} 部 · 下拉刷新',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, color: context.palette.textFaint),
                ),
              ),
            ),
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

class _VodPagedGridState extends State<VodPagedGrid> {
  final ScrollController _controller = ScrollController();
  final List<VodItem> _items = [];

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
    final posterSize = context.select<AppState, PosterSize>((s) => s.posterSize);
    final landscape = context.select<AppState, bool>((s) => s.landscapeCard);

    return LayoutBuilder(
      builder: (context, constraints) {
        if (_items.isEmpty) {
          if (_error != null) {
            return ErrorView(message: _error!, onRetry: _retry);
          }
          if (!_firstLoaded) return const LoadingView(text: '正在加载分类…');
          return const EmptyView(title: '这个分类还没有内容', icon: Icons.inbox_outlined);
        }

        final delegate = _delegateFor(constraints.maxWidth, posterSize, landscape);

        return CustomScrollView(
          controller: _controller,
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(_horizontalPadding, 12, _horizontalPadding, 8),
              sliver: SliverGrid(
                gridDelegate: delegate,
                delegate: SliverChildBuilderDelegate(
                  (context, i) {
                    final vod = _items[i];
                    return VodCard(
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
