import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/cms_api.dart';
import '../models/cms_source.dart';
import '../state/app_state.dart';
import '../widgets/state_views.dart';
import '../widgets/brand_mark.dart';
import '../widgets/vod_card.dart';
import 'category_page.dart';
import 'detail_page.dart';
import 'search_page.dart';
import 'sources_page.dart';
import '../theme/app_palette.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  AppState? _app;
  Future<CmsIndex>? _future;
  String? _loadedSourceId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _attach());
  }

  void _attach() {
    if (!mounted) return;
    final app = context.read<AppState>();
    _app = app;
    app.addListener(_onAppChanged);
    _onAppChanged();
  }

  void _onAppChanged() {
    if (!mounted) return;
    final sourceId = _app?.currentSource?.id;
    if (sourceId == _loadedSourceId) return;
    _loadedSourceId = sourceId;
    _reload();
  }

  void _reload() {
    final app = _app;
    if (app == null || !mounted) return;
    final source = app.currentSource;
    setState(() {
      _future = source == null ? null : app.api.fetchIndex(source);
    });
  }

  Future<void> _refresh() async {
    final app = _app;
    if (app == null) return;
    final source = app.currentSource;
    if (source == null) return;
    final future = app.api.fetchIndex(source);
    setState(() => _future = future);
    try {
      await future;
    } catch (_) {
      // 错误交给 FutureBuilder 呈现。
    }
  }

  @override
  void dispose() {
    _app?.removeListener(_onAppChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final source = app.currentSource;

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 16,
        title: _SourceSelector(
          app: app,
          source: source,
          onManage: () => _openSources(context),
        ),
        actions: [
          IconButton(
            tooltip: '聚合搜索',
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const SearchPage()),
              );
            },
            icon: const Icon(Icons.search),
          ),
          IconButton(
            tooltip: '订阅源管理',
            onPressed: () => _openSources(context),
            icon: const Icon(Icons.dns_outlined),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: source == null
          ? EmptyView(
              badge: const BrandMark(size: 96),
              title: '欢迎使用影枢 CineHub',
              subtitle: '还没有订阅源。添加一个苹果CMS v10 采集接口'
                  '（形如 /api.php/provide/vod/），即可开始点播。',
              actionLabel: '添加订阅源',
              onAction: () => _openSources(context),
            )
          : FutureBuilder<CmsIndex>(
              future: _future,
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.none) {
                  return const LoadingView(text: '准备中…');
                }
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const LoadingView(text: '正在拉取首页…');
                }
                if (snapshot.hasError) {
                  return ErrorView(
                    message: _describeError(snapshot.error),
                    onRetry: _reload,
                  );
                }
                final index = snapshot.data;
                if (index == null) {
                  return ErrorView(message: '接口未返回数据', onRetry: _reload);
                }
                if (index.categories.isEmpty && index.videos.isEmpty) {
                  return EmptyView(
                    icon: Icons.hourglass_empty,
                    title: '这个源暂时没有内容',
                    subtitle: '接口可用，但没有返回分类或影视数据。',
                    actionLabel: '刷新',
                    onAction: _reload,
                  );
                }
                return _buildContent(context, source, index);
              },
            ),
    );
  }

  Widget _buildContent(BuildContext context, CmsSource source, CmsIndex index) {
    return RefreshIndicator(
      onRefresh: _refresh,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          final crossAxisCount = width >= 1100
              ? 7
              : width >= 800
                  ? 5
                  : width >= 600
                      ? 4
                      : 3;
          const horizontalPadding = 16.0;
          const spacing = 12.0;
          final itemWidth = (width -
                  horizontalPadding * 2 -
                  spacing * (crossAxisCount - 1)) /
              crossAxisCount;
          final itemHeight = itemWidth * 1.5 + 44;

          return CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              if (index.categories.isNotEmpty)
                SliverToBoxAdapter(
                  child: SizedBox(
                    height: 46,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: horizontalPadding),
                      itemCount: index.categories.length,
                      separatorBuilder: (_, __) => const SizedBox(width: 8),
                      itemBuilder: (context, i) {
                        final category = index.categories[i];
                        return Center(
                          child: ActionChip(
                            label: Text(category.typeName),
                            onPressed: () {
                              Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) => CategoryPage(
                                    source: source,
                                    category: category,
                                  ),
                                ),
                              );
                            },
                          ),
                        );
                      },
                    ),
                  ),
                ),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(
                  horizontalPadding,
                  8,
                  horizontalPadding,
                  4,
                ),
                sliver: SliverGrid(
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: crossAxisCount,
                    mainAxisSpacing: 16,
                    crossAxisSpacing: spacing,
                    mainAxisExtent: itemHeight,
                  ),
                  delegate: SliverChildBuilderDelegate(
                    (context, i) {
                      final vod = index.videos[i];
                      return VodCard(
                        vod: vod,
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
                    childCount: index.videos.length,
                  ),
                ),
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                  child: Text(
                    '最近更新 ${index.videos.length} 部 · 下拉刷新',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 12, color: context.palette.textFaint),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  void _openSources(BuildContext context) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SourcesPage()));
  }
}

String _describeError(dynamic error) {
  if (error is CmsException) return error.message;
  return '加载失败：$error';
}

class _SourceSelector extends StatelessWidget {
  const _SourceSelector({
    required this.app,
    required this.source,
    required this.onManage,
  });

  final AppState app;
  final CmsSource? source;
  final VoidCallback onManage;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: '切换订阅源',
      position: PopupMenuPosition.under,
      onSelected: (value) {
        if (value == '__manage__') {
          onManage();
          return;
        }
        app.setCurrentSource(value);
      },
      itemBuilder: (context) {
        final items = <PopupMenuEntry<String>>[];
        if (app.sources.isEmpty) {
          items.add(const PopupMenuItem<String>(
            enabled: false,
            value: '__empty__',
            child: Text('暂无订阅源'),
          ));
        } else {
          for (final item in app.sources) {
            items.add(PopupMenuItem<String>(
              value: item.id,
              child: Row(
                children: [
                  Icon(
                    item.enabled ? Icons.check_circle : Icons.remove_circle_outline,
                    size: 16,
                    color: item.enabled ? Colors.greenAccent : context.palette.textFaint,
                  ),
                  const SizedBox(width: 10),
                  Flexible(
                    child: Text(
                      item.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ));
          }
        }
        items.add(const PopupMenuDivider());
        items.add(const PopupMenuItem<String>(
          value: '__manage__',
          child: Text('管理订阅源…'),
        ));
        return items;
      },
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(
              source?.name ?? '未选择源',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700),
            ),
          ),
          Icon(Icons.expand_more, size: 20, color: context.palette.textSecondary),
        ],
      ),
    );
  }
}
