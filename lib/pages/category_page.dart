import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/cms_api.dart';
import '../models/cms_source.dart';
import '../models/vod.dart';
import '../state/app_state.dart';
import '../widgets/state_views.dart';
import '../widgets/vod_card.dart';
import 'detail_page.dart';

/// 分类列表：分页无限加载。
class CategoryPage extends StatefulWidget {
  const CategoryPage({super.key, required this.source, required this.category});

  final CmsSource source;
  final CmsCategory category;

  @override
  State<CategoryPage> createState() => _CategoryPageState();
}

class _CategoryPageState extends State<CategoryPage> {
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
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadMore());
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
            typeId: widget.category.typeId,
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

  int _crossAxisCount(double width) {
    if (width >= 1100) return 7;
    if (width >= 800) return 5;
    if (width >= 600) return 4;
    return 3;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.category.typeName),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Center(
              child: Text(
                widget.source.name,
                style: const TextStyle(fontSize: 12, color: Colors.white38),
              ),
            ),
          ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          if (_items.isEmpty) {
            if (_error != null) {
              return ErrorView(message: _error!, onRetry: _retry);
            }
            if (!_firstLoaded) return const LoadingView(text: '正在加载分类…');
            return const EmptyView(title: '这个分类还没有内容', icon: Icons.inbox_outlined);
          }

          const horizontalPadding = 16.0;
          const spacing = 12.0;
          final crossAxisCount = _crossAxisCount(constraints.maxWidth);
          final itemWidth = (constraints.maxWidth -
                  horizontalPadding * 2 -
                  spacing * (crossAxisCount - 1)) /
              crossAxisCount;
          final itemHeight = itemWidth * 1.5 + 44;

          return CustomScrollView(
            controller: _controller,
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(horizontalPadding, 12, horizontalPadding, 8),
                sliver: SliverGrid(
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: crossAxisCount,
                    mainAxisSpacing: 16,
                    crossAxisSpacing: spacing,
                    mainAxisExtent: itemHeight,
                  ),
                  delegate: SliverChildBuilderDelegate(
                    (context, i) {
                      final vod = _items[i];
                      return VodCard(
                        vod: vod,
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
                  child: Center(child: _footer()),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _footer() {
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
        style: const TextStyle(fontSize: 12, color: Colors.white38),
      );
    }
    return const SizedBox(height: 12);
  }
}
