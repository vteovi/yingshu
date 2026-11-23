import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/image_cache.dart';
import '../core/image_util.dart';
import '../data/cms_api.dart';
import '../state/app_state.dart';
import '../widgets/state_views.dart';
import '../widgets/vod_card.dart';
import '../widgets/vod_grid.dart';
import 'detail_page.dart';
import '../theme/app_palette.dart';

/// 多源聚合搜索。
class SearchPage extends StatefulWidget {
  const SearchPage({super.key});

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();

  List<SearchHit> _hits = const [];
  bool _loading = false;
  String? _error;
  String? _filterSourceId;

  /// 搜索结果用「海报网格」还是之前的「列表」样式。
  bool _listMode = false;

  /// 当前这轮搜索的序号 + 进度，用来丢弃过期回调、并显示「已查 M/N 个源」。
  int _runId = 0;
  int _done = 0;
  int _total = 0;

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final keyword = _controller.text.trim();
    if (keyword.isEmpty) return;
    _focusNode.unfocus();

    final app = context.read<AppState>();
    final sources = app.enabledSources;
    if (sources.isEmpty) {
      setState(() {
        _error = '没有启用的订阅源，请先在首页添加或启用订阅源';
      });
      return;
    }

    final runId = ++_runId;
    setState(() {
      _loading = true;
      _error = null;
      _filterSourceId = null;
      _hits = const [];
      _done = 0;
      _total = sources.length;
    });

    // 边搜边上屏：哪个源先回来就先显示哪个源的结果
    await app.api.searchAllStreaming(
      sources,
      keyword,
      onSourceDone: (hits, source) {
        if (!mounted || runId != _runId) return;
        setState(() {
          _done++;
          if (hits.isNotEmpty) _hits = [..._hits, ...hits];
        });
      },
      onAllDone: () {
        if (!mounted || runId != _runId) return;
        setState(() {
          _loading = false;
          if (_hits.isEmpty) {
            _error = '没有找到「$keyword」，换个关键词或更换订阅源再试';
          }
        });
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final enabledCount = app.enabledSources.length;

    return Scaffold(
      appBar: AppBar(
        title: const Text('聚合搜索'),
        actions: [
          if (_hits.isNotEmpty)
            IconButton(
              tooltip: _listMode ? '切换为海报网格' : '切换为列表',
              onPressed: () => setState(() => _listMode = !_listMode),
              icon: Icon(_listMode ? Icons.grid_view_rounded : Icons.view_list_rounded),
            ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    focusNode: _focusNode,
                    textInputAction: TextInputAction.search,
                    onSubmitted: (_) => _search(),
                    decoration: const InputDecoration(
                      hintText: '输入片名 / 演员，回车搜索',
                      prefixIcon: Icon(Icons.search, size: 20),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                SizedBox(
                  height: 46,
                  child: FilledButton(
                    onPressed: _loading ? null : _search,
                    child: const Text('搜索'),
                  ),
                ),
              ],
            ),
          ),
          if (_hits.isNotEmpty) _buildFilters(),
          if (_loading) const LinearProgressIndicator(minHeight: 2),
          Expanded(child: _buildBody(enabledCount)),
        ],
      ),
    );
  }

  Widget _buildFilters() {
    final sourceCounts = <String, int>{};
    final sourceNames = <String, String>{};
    for (final hit in _hits) {
      sourceCounts[hit.source.id] = (sourceCounts[hit.source.id] ?? 0) + 1;
      sourceNames[hit.source.id] = hit.source.name;
    }

    return SizedBox(
      height: 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilterChip(
              label: Text('全部 ${_hits.length}'),
              selected: _filterSourceId == null,
              onSelected: (_) => setState(() => _filterSourceId = null),
            ),
          ),
          for (final entry in sourceCounts.entries)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilterChip(
                label: Text('${sourceNames[entry.key] ?? ''} ${entry.value}'),
                selected: _filterSourceId == entry.key,
                onSelected: (_) => setState(() => _filterSourceId = entry.key),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildBody(int enabledCount) {
    if (_hits.isEmpty) {
      if (_loading) {
        return LoadingView(text: '正在 $enabledCount 个源中检索，已完成 $_done 个…');
      }
      if (_error != null) {
        return EmptyView(
          icon: Icons.search_off_rounded,
          title: '没有结果',
          subtitle: _error,
        );
      }
      return EmptyView(
        icon: Icons.travel_explore,
        title: '聚合搜索',
        subtitle: enabledCount == 0
            ? '请先添加订阅源'
            : '将在 $enabledCount 个启用的订阅源中同时检索，结果会标注来源。',
      );
    }

    final visible = _filterSourceId == null
        ? _hits
        : _hits.where((hit) => hit.source.id == _filterSourceId).toList(growable: false);

    final posterSize = context.select<AppState, PosterSize>((s) => s.posterSize);
    final landscape = context.select<AppState, bool>((s) => s.useLandscapeCard);
    final layout = context.select<AppState, PosterLayout>((s) => s.posterLayout);

    Widget cardFor(BuildContext ctx, int i) {
      final hit = visible[i];
      return VodCard(
        vod: hit.vod,
        apiBase: hit.source.api,
        landscape: landscape,
        footer: hit.source.name,
        onTap: () => _openDetail(hit),
      );
    }

    String picUrl(int i) => normalizeImageUrl(visible[i].vod.pic, api: visible[i].source.api);

    final Widget status = _loading
        ? Padding(
            padding: const EdgeInsets.symmetric(vertical: 20),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 10),
                Text(
                  '还在检索… 已完成 $_done/$_total 个源',
                  style: TextStyle(fontSize: 12, color: context.palette.textFaint),
                ),
              ],
            ),
          )
        : const SizedBox(height: 28);

    final endPadding = SliverToBoxAdapter(child: status);

    // 列表样式：保留以前「海报 + 文字 + 来源」的横条，海报比例仍跟随设置
    if (_listMode) {
      if (layout == PosterLayout.actual) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          for (var i = 0; i < visible.length; i++) {
            probePosterRatio(context, picUrl(i), visible[i].source.api);
          }
        });
      }
      return ListView.separated(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
        itemCount: visible.length + (_loading ? 1 : 0),
        separatorBuilder: (_, __) => const SizedBox(height: 12),
        itemBuilder: (context, i) {
          if (i >= visible.length) {
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    '还在检索… 已完成 $_done/$_total 个源',
                    style: TextStyle(fontSize: 12, color: context.palette.textFaint),
                  ),
                ],
              ),
            );
          }
          final hit = visible[i];
          return _SearchResultTile(
            hit: hit,
            posterSize: posterSize,
            landscape: landscape,
            actualRatio: layout == PosterLayout.actual,
            onTap: () => _openDetail(hit),
          );
        },
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        // 原始比例：和首页、收藏、历史同一套瀑布流
        if (layout == PosterLayout.actual) {
          return CustomScrollView(
            slivers: [
              SliverToBoxAdapter(
                child: VodMasonryGrid(
                  itemCount: visible.length,
                  size: posterSize,
                  maxWidth: constraints.maxWidth,
                  landscape: landscape,
                  ratioOf: (i) =>
                      PosterRatioStore.instance.ratioOf(picUrl(i)) ?? (landscape ? 16 / 10 : 2 / 3),
                  onLayoutDone: (ctx) {
                    for (var i = 0; i < visible.length; i++) {
                      probePosterRatio(ctx, picUrl(i), visible[i].source.api);
                    }
                  },
                  itemBuilder: cardFor,
                ),
              ),
              endPadding,
            ],
          );
        }

        final spec = vodGridSpec(
          maxWidth: constraints.maxWidth,
          size: posterSize,
          landscape: landscape,
        );
        return CustomScrollView(
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              sliver: SliverGrid(
                gridDelegate: vodGridDelegate(
                  maxWidth: constraints.maxWidth,
                  size: posterSize,
                  landscape: landscape,
                ),
                delegate: SliverChildBuilderDelegate(
                  (context, i) => VodCell(width: spec.width, child: cardFor(context, i)),
                  childCount: visible.length,
                ),
              ),
            ),
            endPadding,
          ],
        );
      },
    );
  }

  void _openDetail(SearchHit hit) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => DetailPage(
          source: hit.source,
          vodId: hit.vod.vodId,
          initialName: hit.vod.name,
          initialPic: hit.vod.pic,
        ),
      ),
    );
  }
}


class _SearchResultTile extends StatelessWidget {
  const _SearchResultTile({
    required this.hit,
    required this.posterSize,
    required this.landscape,
    required this.actualRatio,
    required this.onTap,
  });

  final SearchHit hit;
  final PosterSize posterSize;
  final bool landscape;
  final bool actualRatio;
  final VoidCallback onTap;

  Size _thumbSize() {
    final baseW = switch (posterSize) {
      PosterSize.small => 64.0,
      PosterSize.medium => 76.0,
      PosterSize.large => 88.0,
    };
    if (!actualRatio) {
      return landscape ? Size(baseW * 1.75, baseW * 1.75 / 1.6) : Size(baseW, baseW * 1.5);
    }
    // 原始比例：按海报自身比例定高度，允许在列表里高低错落
    final url = normalizeImageUrl(hit.vod.pic, api: hit.source.api);
    final ratio = PosterRatioStore.instance.ratioOf(url) ?? (landscape ? 16 / 10 : 2 / 3);
    final width = baseW + 8;
    final height = (width / ratio).clamp(56.0, 220.0);
    return Size(width, height);
  }

  @override
  Widget build(BuildContext context) {
    final vod = hit.vod;
    return AnimatedBuilder(
      animation: PosterRatioStore.instance,
      builder: (context, _) {
        final thumb = _thumbSize();
        return InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: SizedBox(
                  width: thumb.width,
                  height: thumb.height,
                  child: vod.pic.isEmpty
                      ? ColoredBox(
                          color: context.palette.surfaceHigh,
                          child: Icon(Icons.movie_outlined, color: context.palette.textFaint),
                        )
                      : CachedNetworkImage(
                          imageUrl: normalizeImageUrl(vod.pic, api: hit.source.api),
                          cacheManager: PosterCacheManager.instance,
                          httpHeaders: imageHeadersFor(hit.source.api),
                          fit: BoxFit.cover,
                          placeholder: (_, __) => ColoredBox(color: context.palette.surfaceHigh),
                          errorWidget: (_, __, ___) => ColoredBox(
                            color: context.palette.surfaceHigh,
                            child: Icon(Icons.movie_outlined, color: context.palette.textFaint),
                          ),
                        ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      vod.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, height: 1.3),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      vod.metaLine.isEmpty ? '暂无信息' : vod.metaLine,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: context.palette.textSecondary, height: 1.4),
                    ),
                    if (vod.actor.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        '主演：${vod.actor}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12, color: context.palette.textFaint),
                      ),
                    ],
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1A2436),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        '来源 · ${hit.source.name}',
                        style: const TextStyle(fontSize: 11, color: Color(0xFF8FD6C8)),
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(left: 8, top: 34),
                child: Icon(Icons.chevron_right, color: context.palette.textFaint, size: 20),
              ),
            ],
          ),
        );
      },
    );
  }
}