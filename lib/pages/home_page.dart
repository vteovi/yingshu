import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/cms_api.dart';
import '../models/cms_source.dart';
import '../state/app_state.dart';
import '../theme/app_palette.dart';
import '../widgets/brand_mark.dart';
import '../widgets/state_views.dart';
import '../widgets/vod_grid.dart';
import 'search_page.dart';
import 'sources_page.dart';

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
                return _HomeTabs(
                  key: ValueKey('${source.id}_${index.categories.length}'),
                  source: source,
                  index: index,
                  onRefresh: _refresh,
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

/// 首页标签：推荐 + 各分类。标签之间可以左右滑动切换，点击标签也只切页、不再跳新页面。
class _HomeTabs extends StatefulWidget {
  const _HomeTabs({
    super.key,
    required this.source,
    required this.index,
    required this.onRefresh,
  });

  final CmsSource source;
  final CmsIndex index;
  final Future<void> Function() onRefresh;

  @override
  State<_HomeTabs> createState() => _HomeTabsState();
}

class _HomeTabsState extends State<_HomeTabs> {
  late final List<CmsCategory?> _tabs = [null, ...widget.index.categories];
  final PageController _pageController = PageController();
  int _current = 0;

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _select(int target) {
    if (target == _current) return;
    setState(() => _current = target);
    _pageController.animateToPage(
      target,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final primary = Theme.of(context).colorScheme.primary;

    return Column(
      children: [
        SizedBox(
          height: 48,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
            itemCount: _tabs.length,
            separatorBuilder: (_, __) => const SizedBox(width: 8),
            itemBuilder: (context, i) {
              final selected = i == _current;
              final title = _tabs[i]?.typeName ?? '推荐';
              return Center(
                child: GestureDetector(
                  onTap: () => _select(i),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                    decoration: BoxDecoration(
                      color: selected
                          ? primary.withValues(alpha: 0.22)
                          : palette.surfaceHigh,
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(
                        color: selected ? primary.withValues(alpha: 0.55) : palette.border,
                      ),
                    ),
                    child: Text(
                      title,
                      style: TextStyle(
                        fontSize: 13,
                        height: 1.1,
                        fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                        color: selected ? palette.textPrimary : palette.textSecondary,
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        Expanded(
          child: PageView.builder(
            controller: _pageController,
            itemCount: _tabs.length,
            onPageChanged: (i) => setState(() => _current = i),
            itemBuilder: (context, i) {
              final category = _tabs[i];
              if (category == null) {
                return VodGridView(
                  videos: widget.index.videos,
                  source: widget.source,
                  onRefresh: widget.onRefresh,
                );
              }
              return VodPagedGrid(
                key: ValueKey('${widget.source.id}_${category.typeId}'),
                source: widget.source,
                typeId: category.typeId,
              );
            },
          ),
        ),
      ],
    );
  }
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
