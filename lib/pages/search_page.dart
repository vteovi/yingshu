import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/image_cache.dart';
import '../core/image_util.dart';
import '../data/cms_api.dart';
import '../models/cms_source.dart';
import '../models/vod.dart';
import '../state/app_state.dart';
import '../widgets/state_views.dart';
import '../widgets/vod_card.dart';
import '../widgets/vod_grid.dart';
import 'detail_page.dart';
import '../theme/app_palette.dart';

/// 多源聚合搜索。
class SearchPage extends StatefulWidget {
  const SearchPage({super.key, this.initialKeyword, this.focusOnOpen = false});

  /// 带关键词进来时（例如首页长按海报）直接搜这一个词，不用用户再输入。
  final String? initialKeyword;

  /// 从首页悬浮按钮进来时打开就聚焦搜索框并弹键盘，省一次点击。
  final bool focusOnOpen;

  @override
  State<SearchPage> createState() => _SearchPageState();
}

/// 搜索范围。
///
/// 术语用「站点」而不是「订阅源」：订阅源是配置层面的一条接口记录，
/// 而搜索时用户想的是「哪个网站有这部片」，站点更贴近这个心智。
enum SearchScope {
  all('全部站点', Icons.public_rounded, '在全部启用的站点里同时检索'),
  current('当前站点', Icons.dns_outlined, '只查首页正在用的那一个站点'),
  local('收藏与历史', Icons.bookmarks_outlined, '只在本机的收藏和观看记录里找，不联网');

  const SearchScope(this.label, this.icon, this.hint);

  final String label;
  final IconData icon;
  final String hint;
}

class _SearchPageState extends State<SearchPage> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();

  /// 搜索范围，默认「全部站点」。
  SearchScope _scope = SearchScope.all;

  /// 上一次真正搜出去的关键词：切换范围时用它决定要不要自动重搜，
  /// 免得用户切完范围还要再点一次「搜索」。
  String? _lastKeyword;

  /// 本地搜索结果的来源标识：'${站点id}|${影片id}' → 「收藏」「看过」「收藏 · 看过」。
  final Map<String, String> _localBadges = {};

  List<SearchHit> _hits = const [];
  bool _loading = false;
  String? _error;
  String? _filterSourceId;

  /// 「全部 / 各来源」筛选标签做成了可左右滑动的分页。
  final PageController _pager = PageController();

  /// 标签条自己的横向滚动：滑动结果区时，标签要跟着一起挪，别让当前标签跑出屏幕。
  final ScrollController _chipsScroll = ScrollController();
  final GlobalKey _chipsViewportKey = GlobalKey();
  final Map<String, GlobalKey> _chipKeys = {};

  /// 每个标签在标签条内容坐标系里的左边缘与宽度（布局后测出来）。
  final Map<String, double> _chipLeft = {};
  final Map<String, double> _chipWidth = {};

  static const String _allChipId = '__all__';
  static const double _chipsPadding = 16;
  static const double _chipsGap = 8;

  String _chipId(String? sourceId) => sourceId ?? _allChipId;

  /// 搜索结果用「海报网格」还是之前的「列表」样式。
  bool _listMode = false;

  /// 当前这轮搜索的序号 + 进度，用来丢弃过期回调、并显示「已查 M/N 个源」。
  int _runId = 0;
  int _done = 0;
  int _total = 0;

  @override
  void initState() {
    super.initState();
    _pager.addListener(_syncChipsWithPager);

    final initial = widget.initialKeyword?.trim() ?? '';
    if (initial.isNotEmpty) {
      _controller.text = initial;
      _controller.selection = TextSelection.collapsed(offset: initial.length);
      // 等首帧布局完成再发请求，不然 setState 会早于页面挂载
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _search();
      });
    } else if (widget.focusOnOpen) {
      // 首帧之后再 requestFocus：页面还没挂上就聚焦，键盘不会弹出来
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _focusNode.requestFocus();
      });
    }
  }

  @override
  void dispose() {
    _pager.removeListener(_syncChipsWithPager);
    _pager.dispose();
    _chipsScroll.dispose();
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  /// 手指拖动结果区时，让标签条按当前页的小数进度同步平移。
  void _syncChipsWithPager() {
    if (!_chipsScroll.hasClients) return;
    final page = _pager.page;
    if (page == null) return;
    final target = _chipsOffsetForPage(page);
    if (target == null) return;
    final position = _chipsScroll.position;
    _chipsScroll.jumpTo(
      target.clamp(position.minScrollExtent, position.maxScrollExtent),
    );
  }

  /// 页 p（可以带小数）对应的标签条滚动偏移：让当前标签居中。
  double? _chipsOffsetForPage(double page) {
    final ids = _filterIds();
    if (ids.isEmpty) return null;
    final viewport = _chipsViewportKey.currentContext?.findRenderObject() as RenderBox?;
    if (viewport == null) return null;
    final width = viewport.size.width;

    double centerOf(int index) {
      final key = _chipId(ids[index.clamp(0, ids.length - 1)]);
      final left = _chipLeft[key];
      final w = _chipWidth[key];
      if (left == null || w == null) return 0;
      return left + w / 2;
    }

    final lower = page.floor();
    final upper = page.ceil();
    final t = page - lower;
    final center = centerOf(lower) * (1 - t) + centerOf(upper) * t;
    return center - width / 2;
  }

  /// 布局完成后量一遍标签的位置，供上面的同步滚动用。
  void _measureChips(List<String?> ids) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      var left = _chipsPadding;
      for (final id in ids) {
        final key = _chipKeys[_chipId(id)];
        final box = key?.currentContext?.findRenderObject() as RenderBox?;
        if (box == null) continue;
        _chipLeft[_chipId(id)] = left;
        _chipWidth[_chipId(id)] = box.size.width;
        left += box.size.width + _chipsGap;
      }
      _syncChipsWithPager();
    });
  }

  Future<void> _search() async {
    final keyword = _controller.text.trim();
    if (keyword.isEmpty) return;
    _focusNode.unfocus();
    _lastKeyword = keyword;

    final app = context.read<AppState>();
    app.addSearchHistory(keyword);

    // 收藏与历史：纯本地过滤，不发请求
    if (_scope == SearchScope.local) {
      _searchLocal(app, keyword);
      return;
    }

    final source = app.currentSource;
    final sources = _scope == SearchScope.current
        ? <CmsSource>[if (source != null) source]
        : app.enabledSources;
    if (sources.isEmpty) {
      setState(() {
        _loading = false;
        _hits = const [];
        _error = _scope == SearchScope.current
            ? '当前站点不可用（可能没启用或已被删除），换「全部站点」再试'
            : '没有启用的站点，请先在首页添加或启用订阅源';
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
    // 新一轮搜索回到「全部」那一页
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _pager.hasClients) _pager.jumpToPage(0);
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

  /// 只在本地记录里找：片名 / 备注包含关键词（不区分大小写），
  /// 收藏与历史里重复的同一部片只留一条。
  void _searchLocal(AppState app, String keyword) {
    final needle = keyword.toLowerCase();
    final hits = <SearchHit>[];
    final seen = <String>{};
    _localBadges.clear();

    void add({
      required String sourceId,
      required String vodId,
      required String name,
      required String pic,
      required String remarks,
      required String badge,
    }) {
      final source = app.findSource(sourceId);
      // 这条记录所属的站点已经删掉了，详情页打不开，就没有搜索的意义
      if (source == null) return;
      final key = '${source.id}|$vodId';
      if (!seen.add(key)) {
        // 同一部片既收藏又看过：合成一个标识，不再重复出一条
        if (_localBadges[key] != badge) _localBadges[key] = '收藏 · 看过';
        return;
      }
      hits.add(SearchHit(
        source: source,
        vod: VodItem(vodId: vodId, name: name, pic: pic, remarks: remarks),
      ));
      _localBadges[key] = badge;
    }

    for (final item in app.favorites) {
      if (item.name.toLowerCase().contains(needle) ||
          item.remarks.toLowerCase().contains(needle)) {
        add(
          sourceId: item.sourceId,
          vodId: item.vodId,
          name: item.name,
          pic: item.pic,
          remarks: item.remarks,
          badge: '收藏',
        );
      }
    }
    for (final item in app.history) {
      if (item.name.toLowerCase().contains(needle)) {
        add(
          sourceId: item.sourceId,
          vodId: item.vodId,
          name: item.name,
          pic: item.pic,
          remarks: '',
          badge: '看过',
        );
      }
    }

    setState(() {
      _loading = false;
      _done = 1;
      _total = 1;
      _filterSourceId = null;
      _hits = hits;
      _error = hits.isEmpty ? '收藏和观看历史里没有「$keyword」。这个范围只查本机记录，不会联网。' : null;
    });
    // 结果换了，结果区回到第一页，免得停在上一次的位置
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _pager.hasClients) _pager.jumpToPage(0);
    });
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
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
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
                const SizedBox(height: 8),
                _buildScopeBar(),
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

  /// 搜索范围选择条：三个胶囊，切换后下一次搜索就按新范围走。
  Widget _buildScopeBar() {
    final app = context.read<AppState>();
    final palette = context.palette;
    final primary = Theme.of(context).colorScheme.primary;
    final localCount = app.favorites.length + app.history.length;

    String labelOf(SearchScope scope) {
      switch (scope) {
        case SearchScope.all:
          return '${scope.label} ${app.enabledSources.length}';
        case SearchScope.current:
          return app.currentSource?.name ?? scope.label;
        case SearchScope.local:
          return '${scope.label} $localCount';
      }
    }

    return Wrap(
      spacing: 8,
      runSpacing: 6,
      children: [
        for (final scope in SearchScope.values)
          ChoiceChip(
            avatar: Icon(
              scope.icon,
              size: 15,
              color: _scope == scope ? primary : palette.textSecondary,
            ),
            label: Text(
              labelOf(scope),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                height: 1.1,
                fontWeight: _scope == scope ? FontWeight.w600 : FontWeight.w400,
                color: _scope == scope ? palette.textPrimary : palette.textSecondary,
              ),
            ),
            selected: _scope == scope,
            visualDensity: VisualDensity.compact,
            onSelected: (_) {
              if (_scope == scope) return;
              // 先作废还在跑的那一轮：否则旧范围的结果会继续追加进来，
              // 显示在新范围下面，看着就像「搜索串了」
              _runId++;
              final rerun = _lastKeyword != null && _controller.text.trim().isNotEmpty;
              setState(() {
                _scope = scope;
                // 换范围等于换一批结果，旧的先清掉，免得分不清是哪个范围搜出来的
                _hits = const [];
                _loading = false;
                _error = null;
                _done = 0;
                _total = 0;
                _filterSourceId = null;
              });
              // 已经搜过一次的话，换范围直接用手上的关键词重搜一遍，
              // 不用用户再点一次「搜索」
              if (rerun) unawaited(_search());
            },
          ),
      ],
    );
  }

  /// 筛选标签的 id 顺序：null 代表「全部」，后面按首次出结果的顺序列各来源。
  List<String?> _filterIds() {
    final ids = <String?>[null];
    final seen = <String>{};
    for (final hit in _hits) {
      if (seen.add(hit.source.id)) ids.add(hit.source.id);
    }
    return ids;
  }

  void _selectFilter(String? id) {
    if (_filterSourceId == id) return;
    final ids = _filterIds();
    final target = ids.indexOf(id);
    setState(() => _filterSourceId = id);
    if (target >= 0 && _pager.hasClients) {
      _pager.animateToPage(
        target,
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOutCubic,
      );
    }
  }

  Widget _buildFilters() {
    final sourceCounts = <String, int>{};
    final sourceNames = <String, String>{};
    for (final hit in _hits) {
      sourceCounts[hit.source.id] = (sourceCounts[hit.source.id] ?? 0) + 1;
      sourceNames[hit.source.id] = hit.source.name;
    }

    final ids = _filterIds();
    _measureChips(ids);

    return SizedBox(
      key: _chipsViewportKey,
      height: 40,
      child: SingleChildScrollView(
        controller: _chipsScroll,
        scrollDirection: Axis.horizontal,
        physics: const ClampingScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: _chipsPadding),
        // 用 Row 而不是 ListView：Row 会把每个标签都排一遍，位置量得准，
        // 同步滚动时不会因为「离屏没布局」而算错。
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
          Padding(
            padding: EdgeInsets.only(right: _chipsGap),
            child: FilterChip(
              key: _chipKeys.putIfAbsent(_allChipId, () => GlobalKey()),
              label: Text('全部 ${_hits.length}'),
              selected: _filterSourceId == null,
              onSelected: (_) => _selectFilter(null),
            ),
          ),
          for (final entry in sourceCounts.entries)
            Padding(
              padding: EdgeInsets.only(right: _chipsGap),
              child: FilterChip(
                key: _chipKeys.putIfAbsent(_chipId(entry.key), () => GlobalKey()),
                label: Text('${sourceNames[entry.key] ?? ''} ${entry.value}'),
                selected: _filterSourceId == entry.key,
                onSelected: (_) => _selectFilter(entry.key),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSearchHistory(List<String> history) {
    final app = context.read<AppState>();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '搜索记录',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: context.palette.textSecondary,
                ),
              ),
              const Spacer(),
              TextButton(
                onPressed: () => _confirmClearHistory(app),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
                child: const Text('清除全部', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
          Wrap(
            spacing: 8,
            runSpacing: 2,
            children: [
              for (final keyword in history)
                InputChip(
                  label: Text(keyword),
                  visualDensity: VisualDensity.compact,
                  onPressed: () {
                    _controller.text = keyword;
                    _controller.selection = TextSelection.collapsed(offset: keyword.length);
                    _search();
                  },
                  onDeleted: () => app.removeSearchHistory(keyword),
                  deleteIcon: const Icon(Icons.close, size: 16),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _confirmClearHistory(AppState app) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('清除搜索记录'),
        content: const Text('所有搜索记录都会被删除，且无法恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('清除'),
          ),
        ],
      ),
    );
    if (ok == true) await app.clearSearchHistory();
  }

  Widget _buildBody(int enabledCount) {
    final searching = _scope == SearchScope.local
        ? '正在收藏与历史中查找…'
        : _scope == SearchScope.current
            ? '正在当前站点中检索…'
            : '正在 $enabledCount 个站点中检索，已完成 $_done 个…';
    if (_hits.isEmpty) {
      if (_loading) {
        return LoadingView(text: searching);
      }
      final history = context.select<AppState, List<String>>((s) => s.searchHistory);
      final empty = _error != null
          ? EmptyView(icon: Icons.search_off_rounded, title: '没有结果', subtitle: _error)
          : EmptyView(
              icon: Icons.travel_explore,
              title: '聚合搜索',
              subtitle: _scope == SearchScope.local
                  ? '在收藏与观看历史里按片名查找，不联网。'
                  : _scope == SearchScope.current
                      ? '只查首页正在用的那个站点。'
                      : enabledCount == 0
                          ? '请先添加订阅源'
                          : '将在 $enabledCount 个启用的站点中同时检索，结果会标注来源。',
            );
      if (history.isEmpty) return empty;
      // 有搜索记录时：空状态在上，下面列最近搜过的关键词
      return ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [empty, _buildSearchHistory(history)],
      );
    }

    final ids = _filterIds();
    if (_filterSourceId != null && ids.indexOf(_filterSourceId) < 0) {
      // 该来源这轮还没出结果（或已消失）：回到「全部」，避免页索引越界
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(() => _filterSourceId = null);
        if (_pager.hasClients) _pager.jumpToPage(0);
      });
    }

    // 结果区做成横向分页：左右滑动即可在「全部 / 各来源」之间切换，顶部标签同步高亮
    return PageView.builder(
      controller: _pager,
      itemCount: ids.length,
      onPageChanged: (i) {
        final id = ids[i];
        if (id != _filterSourceId) setState(() => _filterSourceId = id);
      },
      itemBuilder: (context, i) => _buildResults(ids[i]),
    );
  }

  Widget _buildResults(String? filterId) {
    final visible = filterId == null
        ? _hits
        : _hits.where((hit) => hit.source.id == filterId).toList(growable: false);

    final posterSize = context.select<AppState, PosterSize>((s) => s.posterSize);
    final landscape = context.select<AppState, bool>((s) => s.useLandscapeCard);
    final layout = context.select<AppState, PosterLayout>((s) => s.posterLayout);

    Widget cardFor(BuildContext ctx, int i) {
      final hit = visible[i];
      return VodCard(
        vod: hit.vod,
        apiBase: hit.source.api,
        landscape: landscape,
        footer: _footerOf(hit),
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
            badge: _badgeOf(hit),
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

  /// 本地结果里这条记录的来源标识（收藏 / 看过），非本地范围返回空串。
  String _badgeOf(SearchHit hit) {
    if (_scope != SearchScope.local) return '';
    return _localBadges['${hit.source.id}|${hit.vod.vodId}'] ?? '';
  }

  /// 卡片底部那行小字：本地范围带上「收藏 / 看过」，远程范围只写站点名。
  String _footerOf(SearchHit hit) {
    final badge = _badgeOf(hit);
    return badge.isEmpty ? hit.source.name : '$badge · ${hit.source.name}';
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
    required this.badge,
    required this.posterSize,
    required this.landscape,
    required this.actualRatio,
    required this.onTap,
  });

  final SearchHit hit;

  /// 本地搜索结果的来源标识（收藏 / 看过 / 收藏 · 看过），远程搜索为空串。
  final String badge;
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
                      : Image(
                          image: PosterImageProvider(
                            normalizeImageUrl(vod.pic, api: hit.source.api),
                            headers: imageHeadersFor(hit.source.api),
                            width: thumb.width.round(),
                          ),
                          fit: BoxFit.cover,
                          gaplessPlayback: true,
                          errorBuilder: (_, __, ___) => ColoredBox(
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
                        badge.isEmpty
                            ? '来源 · ${hit.source.name}'
                            : '$badge · ${hit.source.name}',
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