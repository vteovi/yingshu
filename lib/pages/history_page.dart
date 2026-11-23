import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/image_cache.dart';
import '../core/image_util.dart';
import '../models/media_record.dart';
import '../models/vod.dart';
import '../state/app_state.dart';
import '../widgets/state_views.dart';
import '../widgets/vod_card.dart';
import '../widgets/vod_grid.dart';
import 'detail_page.dart';
import '../theme/app_palette.dart';

class HistoryPage extends StatelessWidget {
  const HistoryPage({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final history = app.history;

    return Scaffold(
      appBar: AppBar(
        title: const Text('观看历史'),
        actions: [
          if (history.isNotEmpty)
            PopupMenuButton<String>(
              onSelected: (_) => _confirmClear(context, app),
              itemBuilder: (context) => const [
                PopupMenuItem(value: 'clear', child: Text('清空历史')),
              ],
            ),
        ],
      ),
      body: history.isEmpty
          ? const EmptyView(
              icon: Icons.history,
              title: '还没有观看记录',
              subtitle: '播放过的影片会自动出现在这里，下次可一键续播。',
            )
          : Builder(
              builder: (context) {
                final posterSize = context.select<AppState, PosterSize>((s) => s.posterSize);
                final landscape = context.select<AppState, bool>((s) => s.useLandscapeCard);
                final thumbSize = switch (posterSize) {
                  PosterSize.small => const Size(52, 74),
                  PosterSize.medium => const Size(62, 88),
                  PosterSize.large => const Size(74, 105),
                };

                if (landscape) {
                  return LayoutBuilder(
                    builder: (context, constraints) {
                      final spec = vodGridSpec(
                        maxWidth: constraints.maxWidth,
                        size: posterSize,
                        landscape: true,
                      );
                      return GridView.builder(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                        gridDelegate: vodGridDelegate(
                          maxWidth: constraints.maxWidth,
                          size: posterSize,
                          landscape: true,
                        ),
                        itemCount: history.length,
                        itemBuilder: (context, i) {
                          final item = history[i];
                          return VodCell(
                            width: spec.width,
                            child: VodCard(
                              vod: VodItem(
                                vodId: item.vodId,
                                name: item.name,
                                pic: item.pic,
                              ),
                              landscape: true,
                              footer: _historyFooter(item),
                              onTap: () => _resume(context, app, item),
                              onLongPress: () => app.removeHistory(item.sourceId, item.vodId),
                            ),
                          );
                        },
                      );
                    },
                  );
                }

                return ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                  itemCount: history.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 12),
                  itemBuilder: (context, i) {
                    final item = history[i];
                    return _HistoryTile(
                      item: item,
                      thumbSize: thumbSize,
                      onTap: () => _resume(context, app, item),
                      onDelete: () => app.removeHistory(item.sourceId, item.vodId),
                    );
                  },
                );
              },
            ),
    );
  }

  void _resume(BuildContext context, AppState app, HistoryItem item) {
    final source = app.findSource(item.sourceId);
    if (source == null) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('这条记录所属的订阅源已被删除')));
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => DetailPage(
          source: source,
          vodId: item.vodId,
          initialName: item.name,
          initialPic: item.pic,
          autoPlayEpisodeUrl: item.episodeUrl.isEmpty ? null : item.episodeUrl,
        ),
      ),
    );
  }

  Future<void> _confirmClear(BuildContext context, AppState app) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清空历史'),
        content: const Text('所有观看记录都会被删除，且无法恢复。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('清空')),
        ],
      ),
    );
    if (ok == true) await app.clearHistory();
  }
}

class _HistoryTile extends StatelessWidget {
  const _HistoryTile({
    required this.item,
    required this.thumbSize,
    required this.onTap,
    required this.onDelete,
  });

  final HistoryItem item;
  final Size thumbSize;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: context.palette.surface,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(9),
              child: SizedBox(
                width: thumbSize.width,
                height: thumbSize.height,
                child: item.pic.isEmpty
                    ? ColoredBox(
                        color: context.palette.surfaceHigh,
                        child: Icon(Icons.movie_outlined, color: context.palette.textFaint, size: 22),
                      )
                    : CachedNetworkImage(
                        imageUrl: normalizeImageUrl(item.pic),
                      cacheManager: PosterCacheManager.instance,
                        httpHeaders: imageHeadersFor(null),
                        fit: BoxFit.cover,
                        placeholder: (_, __) => ColoredBox(color: context.palette.surfaceHigh),
                        errorWidget: (_, __, ___) => ColoredBox(
                          color: context.palette.surfaceHigh,
                          child: Icon(Icons.movie_outlined, color: context.palette.textFaint, size: 22),
                        ),
                      ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          item.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                        ),
                      ),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        tooltip: '删除记录',
                        onPressed: onDelete,
                        icon: Icon(Icons.close, size: 16, color: context.palette.textFaint),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    [
                      if (item.episodeName.isNotEmpty) '看到 ${item.episodeName}',
                      if (item.positionMs > 0) _formatDuration(item.position),
                    ].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: context.palette.textSecondary),
                  ),
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: LinearProgressIndicator(
                      value: item.progress,
                      minHeight: 3,
                      backgroundColor: context.palette.textFaint,
                      color: const Color(0xFF7FA6FF),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          item.sourceName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 11, color: context.palette.textFaint),
                        ),
                      ),
                      Text(
                        _relativeTime(item.updatedAt),
                        style: TextStyle(fontSize: 11, color: context.palette.textFaint),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _historyFooter(HistoryItem item) {
  return [
    if (item.episodeName.isNotEmpty) '看到 ${item.episodeName}',
    if (item.positionMs > 0) _formatDuration(item.position),
    item.sourceName,
  ].join(' · ');
}

String _formatDuration(Duration value) {
  final hours = value.inHours;
  final minutes = value.inMinutes.remainder(60).toString().padLeft(2, '0');
  final seconds = value.inSeconds.remainder(60).toString().padLeft(2, '0');
  return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
}

String _relativeTime(int millis) {
  if (millis <= 0) return '';
  final diff = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(millis));
  if (diff.inMinutes < 1) return '刚刚';
  if (diff.inHours < 1) return '${diff.inMinutes} 分钟前';
  if (diff.inDays < 1) return '${diff.inHours} 小时前';
  if (diff.inDays < 30) return '${diff.inDays} 天前';
  final date = DateTime.fromMillisecondsSinceEpoch(millis);
  return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
}

