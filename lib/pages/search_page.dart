import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

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
      appBar: AppBar(title: const Text('聚合搜索')),
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

