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

int _crossAxisCount(double width) {
  if (width >= 1100) return 7;
  if (width >= 800) return 5;
  if (width >= 600) return 4;
  return 3;
}

const double _horizontalPadding = 16.0;
const double _spacing = 12.0;

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
    final content = LayoutBuilder(
      builder: (context, constraints) {
        final crossAxisCount = _crossAxisCount(constraints.maxWidth);
        final itemWidth = (constraints.maxWidth -
                _horizontalPadding * 2 -
                _spacing * (crossAxisCount - 1)) /
            crossAxisCount;
        final itemHeight = itemWidth * 1.5 + 44;

        return CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(_horizontalPadding, 10, _horizontalPadding, 4),
              sliver: SliverGrid(
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: crossAxisCount,
                  mainAxisSpacing: 16,
                  crossAxisSpacing: _spacing,
                  mainAxisExtent: itemHeight,
                ),
                delegate: SliverChildBuilderDelegate(
                  (context, i) {
                    final vod = videos[i];
                    return VodCard(
                      vod: vod,
                      apiBase: source.api,
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
    return LayoutBuilder(
      builder: (context, constraints) {
        if (_items.isEmpty) {
          if (_error != null) {
            return ErrorView(message: _error!, onRetry: _retry);
          }
          if (!_firstLoaded) return const LoadingView(text: '正在加载分类…');
          return const EmptyView(title: '这个分类还没有内容', icon: Icons.inbox_outlined);
        }

        final crossAxisCount = _crossAxisCount(constraints.maxWidth);
        final itemWidth = (constraints.maxWidth -
                _horizontalPadding * 2 -
                _spacing * (crossAxisCount - 1)) /
            crossAxisCount;
        final itemHeight = itemWidth * 1.5 + 44;

        return CustomScrollView(
          controller: _controller,
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(_horizontalPadding, 12, _horizontalPadding, 8),
              sliver: SliverGrid(
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: crossAxisCount,
                  mainAxisSpacing: 16,
                  crossAxisSpacing: _spacing,
                  mainAxisExtent: itemHeight,
                ),
                delegate: SliverChildBuilderDelegate(
                  (context, i) {
                    final vod = _items[i];
                    return VodCard(
                      vod: vod,
                      apiBase: widget.source.api,
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
