import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/cms_api.dart';
import '../state/app_state.dart';
import '../widgets/state_views.dart';
import 'detail_page.dart';

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

    setState(() {
      _loading = true;
      _error = null;
      _filterSourceId = null;
      _hits = const [];
    });

    final hits = await app.api.searchAll(sources, keyword);
    if (!mounted) return;
    setState(() {
      _loading = false;
      _hits = hits;
      if (hits.isEmpty) {
        _error = '没有找到「$keyword」，换个关键词或更换订阅源再试';
      }
    });
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
    if (_loading) {
      return LoadingView(text: '正在 $enabledCount 个源中检索…');
    }
    if (_hits.isEmpty) {
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

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
      itemCount: visible.length,
      separatorBuilder: (_, __) => const SizedBox(height: 12),
      itemBuilder: (context, i) => _SearchResultTile(
        hit: visible[i],
        onTap: () => _openDetail(visible[i]),
      ),
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
  const _SearchResultTile({required this.hit, required this.onTap});

  final SearchHit hit;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final vod = hit.vod;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: SizedBox(
              width: 76,
              height: 106,
              child: vod.pic.isEmpty
                  ? const ColoredBox(
                      color: Color(0xFF1B1B24),
                      child: Icon(Icons.movie_outlined, color: Colors.white24),
                    )
                  : CachedNetworkImage(
                      imageUrl: vod.pic,
                      fit: BoxFit.cover,
                      placeholder: (_, __) => const ColoredBox(color: Color(0xFF1B1B24)),
                      errorWidget: (_, __, ___) => const ColoredBox(
                        color: Color(0xFF1B1B24),
                        child: Icon(Icons.movie_outlined, color: Colors.white24),
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
                  style: const TextStyle(fontSize: 12, color: Colors.white54, height: 1.4),
                ),
                if (vod.actor.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    '主演：${vod.actor}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12, color: Colors.white38),
                  ),
                ],
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: const Color(0xFF23232F),
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
          const Padding(
            padding: EdgeInsets.only(left: 8, top: 34),
            child: Icon(Icons.chevron_right, color: Colors.white24, size: 20),
          ),
        ],
      ),
    );
  }
}
