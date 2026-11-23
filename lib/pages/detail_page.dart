import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/external_player.dart';
import '../core/image_cache.dart';
import '../core/image_util.dart';
import '../core/play_resolver.dart';
import '../data/cms_api.dart';
import '../models/cms_source.dart';
import '../models/episode.dart';
import '../models/media_record.dart';
import '../models/vod.dart';
import '../state/app_state.dart';
import '../widgets/state_views.dart';
import 'player_page.dart';
import '../theme/app_palette.dart';

class DetailPage extends StatefulWidget {
  const DetailPage({
    super.key,
    required this.source,
    required this.vodId,
    this.initialName = '',
    this.initialPic = '',
    this.autoPlayEpisodeUrl,
  });

  final CmsSource source;
  final String vodId;
  final String initialName;
  final String initialPic;

  /// 从历史记录续播时传入上次的剧集地址，详情加载完成后自动跳转播放。
  final String? autoPlayEpisodeUrl;

  @override
  State<DetailPage> createState() => _DetailPageState();
}

class _DetailPageState extends State<DetailPage> {
  Future<VodItem?>? _future;
  int _groupIndex = 0;
  bool _descriptionExpanded = false;
  bool _autoPlayHandled = false;
  bool _openingExternal = false;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<VodItem?> _load() async {
    final app = context.read<AppState>();
    final VodItem? vod = await app.api.fetchDetail(widget.source, widget.vodId);

    if (vod != null && widget.autoPlayEpisodeUrl != null && !_autoPlayHandled) {
      _autoPlayHandled = true;
      final groups = parsePlayGroups(vod.playFrom, vod.playUrl);
      int groupIndex = -1;
      int episodeIndex = -1;
      for (var i = 0; i < groups.length && groupIndex < 0; i++) {
        final index = groups[i].episodes.indexWhere((e) => e.url == widget.autoPlayEpisodeUrl);
        if (index >= 0) {
          groupIndex = i;
          episodeIndex = index;
        }
      }
      if (groupIndex >= 0) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          setState(() => _groupIndex = groupIndex);
          final history = app.historyFor(widget.source.id, vod.vodId);
          _openPlayer(
            vod,
            groups[groupIndex],
            episodeIndex,
            startPosition: history?.position,
          );
        });
      }
    }
    return vod;
  }

  void _openPlayer(
    VodItem vod,
    PlaySourceGroup group,
    int index, {
    Duration? startPosition,
  }) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PlayerPage(
          sourceId: widget.source.id,
          sourceName: widget.source.name,
          vodId: vod.vodId,
          vodName: vod.name,
          vodPic: vod.pic,
          groupName: group.from,
          episodes: group.episodes,
          initialIndex: index,
          initialPosition: startPosition,
        ),
      ),
    );
  }

  /// 用第三方播放器打开当前选集：先解析出真正的 m3u8/mp4 地址，再交给系统。
  Future<void> _openExternal(
    VodItem vod,
    PlaySourceGroup group,
    int index,
  ) async {
    if (_openingExternal) return;
    setState(() => _openingExternal = true);
    final app = context.read<AppState>();
    final episode = group.episodes[index];
    try {
      final url = await PlayResolver().resolve(
        episode.url,
        userAgent: app.userAgent,
      );
      if (!mounted) return;
      await ExternalPlayer.open(url, title: '${vod.name} · ${episode.name}');
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text('已交给系统选择播放器：$url'),
            duration: const Duration(seconds: 4),
          ),
        );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('打开失败：$error')));
    } finally {
      if (mounted) setState(() => _openingExternal = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<VodItem?>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return Scaffold(
            appBar: AppBar(title: Text(widget.initialName.isEmpty ? '详情' : widget.initialName)),
            body: const LoadingView(text: '正在获取详情…'),
          );
        }
        if (snapshot.hasError) {
          final error = snapshot.error;
          return Scaffold(
            appBar: AppBar(title: Text(widget.initialName.isEmpty ? '详情' : widget.initialName)),
            body: ErrorView(
              message: error is CmsException ? error.message : '详情加载失败：$error',
              onRetry: () => setState(() => _future = _load()),
            ),
          );
        }
        final vod = snapshot.data;
        if (vod == null) {
          return Scaffold(
            appBar: AppBar(title: Text(widget.initialName.isEmpty ? '详情' : widget.initialName)),
            body: EmptyView(
              icon: Icons.movie_filter_outlined,
              title: '没有找到这部片子的详情',
              subtitle: '可能是源站已下架，换一个源再搜索试试。',
              actionLabel: '重试',
              onAction: () => setState(() => _future = _load()),
            ),
          );
        }
        return _buildDetail(context, vod);
      },
    );
  }

  Widget _buildDetail(BuildContext context, VodItem vod) {
    final app = context.watch<AppState>();
    final groups = parsePlayGroups(vod.playFrom, vod.playUrl);
    final groupIndex = groups.isEmpty ? 0 : _groupIndex.clamp(0, groups.length - 1).toInt();
    final isFavorite = app.isFavorite(widget.source.id, vod.vodId);
    final history = app.historyFor(widget.source.id, vod.vodId);

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Text(
          vod.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
      ),
      extendBodyBehindAppBar: true,
      body: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(child: _buildHeader(context, vod)),
          SliverToBoxAdapter(child: _buildInfo(context, vod)),
          if (groups.isNotEmpty)
            SliverToBoxAdapter(
              child: _buildEpisodes(
                context,
                vod: vod,
                groups: groups,
                groupIndex: groupIndex,
                historyEpisodeUrl: history?.episodeUrl,
              ),
            ),
          const SliverToBoxAdapter(child: SizedBox(height: 24)),
        ],
      ),
      bottomNavigationBar: _buildBottomBar(
        context,
        vod: vod,
        groups: groups,
        groupIndex: groupIndex,
        isFavorite: isFavorite,
        history: history,
      ),
    );
  }

  Widget _buildHeader(BuildContext context, VodItem vod) {
    final pic = normalizeImageUrl(
      vod.pic.isNotEmpty ? vod.pic : widget.initialPic,
      api: widget.source.api,
    );
    return SizedBox(
      height: 320,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (pic.isNotEmpty)
            Image(
              image: PosterImageProvider(
                pic,
                headers: imageHeadersFor(widget.source.api),
                width: 900,
              ),
              fit: BoxFit.cover,
              gaplessPlayback: true,
              errorBuilder: (_, __, ___) => ColoredBox(color: context.palette.surfaceHigh),
            )
          else
            ColoredBox(color: context.palette.surfaceHigh),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  context.palette.background.withValues(alpha: 0.80),
                  context.palette.background.withValues(alpha: 0.53),
                  context.palette.background,
                ],
                stops: [0.0, 0.45, 1.0],
              ),
            ),
          ),
          Positioned(
            left: 16,
            right: 16,
            bottom: 16,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (vod.score.isNotEmpty)
                  Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF5C518),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      '评分 ${vod.score}',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: Colors.black,
                      ),
                    ),
                  ),
                Text(
                  vod.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 24,
                    height: 1.25,
                    fontWeight: FontWeight.w800,
                    color: context.palette.textPrimary,
                  ),
                ),
                if (vod.metaLine.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    vod.metaLine,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13, color: context.palette.textSecondary),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInfo(BuildContext context, VodItem vod) {
    final theme = Theme.of(context);
    final hasLongContent = vod.cleanContent.length > 80;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (vod.actor.isNotEmpty || vod.director.isNotEmpty)
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: context.palette.surface,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (vod.director.isNotEmpty)
                    _InfoRow(label: '导演', value: vod.director),
                  if (vod.actor.isNotEmpty)
                    _InfoRow(label: '主演', value: vod.actor, spaced: vod.director.isNotEmpty),
                  if (vod.lang.isNotEmpty || vod.updatedAt.isNotEmpty)
                    _InfoRow(
                      label: '信息',
                      value: [
                        if (vod.lang.isNotEmpty) vod.lang,
                        if (vod.updatedAt.isNotEmpty) '更新 ${vod.updatedAt}',
                      ].join(' · '),
                      spaced: vod.actor.isNotEmpty || vod.director.isNotEmpty,
                    ),
                ],
              ),
            ),
          const SizedBox(height: 18),
          Row(
            children: [
              Text(
                '剧情简介',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: theme.colorScheme.onSurface,
                ),
              ),
              const Spacer(),
              if (vod.score.isNotEmpty)
                Text('评分 ${vod.score}', style: TextStyle(fontSize: 12, color: context.palette.textFaint)),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            vod.cleanContent.isEmpty ? '暂无简介' : vod.cleanContent,
            maxLines: _descriptionExpanded ? null : 4,
            overflow: _descriptionExpanded ? TextOverflow.visible : TextOverflow.ellipsis,
            style: TextStyle(fontSize: 13, height: 1.7, color: context.palette.textSecondary),
          ),
          if (hasLongContent)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: () => setState(() => _descriptionExpanded = !_descriptionExpanded),
                style: TextButton.styleFrom(padding: EdgeInsets.zero, minimumSize: const Size(0, 32)),
                child: Text(_descriptionExpanded ? '收起' : '展开全部'),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildEpisodes(
    BuildContext context, {
    required VodItem vod,
    required List<PlaySourceGroup> groups,
    required int groupIndex,
    required String? historyEpisodeUrl,
  }) {
    final group = groups[groupIndex];
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Divider(height: 24),
          Row(
            children: [
              const Text(
                '选集',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
              ),
              const SizedBox(width: 8),
              Text(
                '共 ${group.episodes.length} 集',
                style: TextStyle(fontSize: 12, color: context.palette.textFaint),
              ),
            ],
          ),
          if (groups.length > 1) ...[
            const SizedBox(height: 10),
            SizedBox(
              height: 38,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: groups.length,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (context, i) => Center(
                  child: ChoiceChip(
                    label: Text(groups[i].from),
                    selected: i == groupIndex,
                    onSelected: (_) => setState(() => _groupIndex = i),
                  ),
                ),
              ),
            ),
          ],
          const SizedBox(height: 14),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (var i = 0; i < group.episodes.length; i++)
                _EpisodeButton(
                  label: group.episodes[i].name,
                  highlight: historyEpisodeUrl != null && group.episodes[i].url == historyEpisodeUrl,
                  onTap: () => _openPlayer(vod, group, i),
                ),
            ],
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Widget _buildBottomBar(
    BuildContext context, {
    required VodItem vod,
    required List<PlaySourceGroup> groups,
    required int groupIndex,
    required bool isFavorite,
    required HistoryItem? history,
  }) {
    final app = context.read<AppState>();
    String label = '暂无播放源';
    int? resumeIndex;

    if (groups.isNotEmpty) {
      final group = groups[groupIndex];
      final historyUrl = history?.episodeUrl;
      if (historyUrl != null && historyUrl.isNotEmpty) {
        final index = group.episodes.indexWhere((e) => e.url == historyUrl);
        if (index >= 0) {
          resumeIndex = index;
          label = '继续播放 · ${group.episodes[index].name}';
        }
      }
      label = resumeIndex == null ? '立即播放 · ${group.episodes.first.name}' : label;
    }

    return SafeArea(
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
        decoration: BoxDecoration(
          color: context.palette.surfaceHigh,
          border: Border(top: BorderSide(color: Color(0xFF1A2436))),
        ),
        child: Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: groups.isEmpty
                    ? null
                    : () => _openPlayer(
                          vod,
                          groups[groupIndex],
                          resumeIndex ?? 0,
                          startPosition: resumeIndex != null ? history?.position : null,
                        ),
                icon: const Icon(Icons.play_arrow_rounded),
                label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filledTonal(
              tooltip: '用第三方播放器打开',
              onPressed: (groups.isEmpty || _openingExternal)
                  ? null
                  : () => _openExternal(
                        vod,
                        groups[groupIndex],
                        resumeIndex ?? 0,
                      ),
              icon: _openingExternal
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.open_in_new_rounded),
            ),
            const SizedBox(width: 8),
            IconButton.filledTonal(
              tooltip: isFavorite ? '取消收藏' : '收藏',
              onPressed: () async {
                final added = await app.toggleFavorite(source: widget.source, vod: vod);
                if (!context.mounted) return;
                ScaffoldMessenger.of(context)
                  ..hideCurrentSnackBar()
                  ..showSnackBar(SnackBar(content: Text(added ? '已加入收藏' : '已取消收藏')));
              },
              icon: Icon(isFavorite ? Icons.favorite : Icons.favorite_border),
            ),
          ],
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value, this.spaced = false});

  final String label;
  final String value;
  final bool spaced;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(top: spaced ? 6 : 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 36,
            child: Text(label, style: TextStyle(fontSize: 12, color: context.palette.textFaint)),
          ),
          Expanded(
            child: Text(
              value,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, height: 1.5, color: context.palette.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}

class _EpisodeButton extends StatelessWidget {
  const _EpisodeButton({required this.label, required this.onTap, this.highlight = false});

  final String label;
  final VoidCallback onTap;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 不再写死 78×38：短标签保持原来的小方块观感，长标签（“第12集 大结局”这类）
    // 会自动变宽、最多折两行，不会再被截成省略号。
    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 78, maxWidth: 168, minHeight: 38),
      child: Material(
        color: highlight ? theme.colorScheme.primary.withOpacity(0.22) : context.palette.surfaceHigh,
        borderRadius: BorderRadius.circular(9),
        child: InkWell(
          borderRadius: BorderRadius.circular(9),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Center(
              child: Text(
                label,
                maxLines: 2,
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  height: 1.3,
                  color: highlight ? context.palette.textPrimary : context.palette.textSecondary,
                  fontWeight: highlight ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
