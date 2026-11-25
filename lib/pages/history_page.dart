import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/image_util.dart';
import '../models/media_record.dart';
import '../models/vod.dart';
import '../state/app_state.dart';
import '../widgets/count_title.dart';
import '../widgets/state_views.dart';
import '../widgets/vod_card.dart';
import '../widgets/vod_grid.dart';
import 'detail_page.dart';

/// 观看历史：卡片样式、竖版/横版/原始比例全部跟随首页设置。
class HistoryPage extends StatelessWidget {
  const HistoryPage({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final history = app.history;

    return Scaffold(
      appBar: AppBar(
        title: CountTitle(title: '观看历史', count: history.length, unit: '部'),
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
                final layout = context.select<AppState, PosterLayout>((s) => s.posterLayout);

                String picUrl(HistoryItem item) =>
                    normalizeImageUrl(item.pic, api: app.findSource(item.sourceId)?.api);

                Widget cardFor(BuildContext ctx, int i) {
                  final item = history[i];
                  return VodCard(
                    vod: VodItem(vodId: item.vodId, name: item.name, pic: item.pic),
                    apiBase: app.findSource(item.sourceId)?.api,
                    landscape: landscape,
                    footer: _historyFooter(item),
                    onTap: () => _resume(ctx, app, item),
                    onLongPress: () => app.removeHistory(item.sourceId, item.vodId),
                  );
                }

                return LayoutBuilder(
                  builder: (context, constraints) {
                    // 原始比例：和首页同一套瀑布流
                    if (layout == PosterLayout.actual) {
                      return SingleChildScrollView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: const EdgeInsets.only(bottom: 24),
                        child: VodMasonryGrid(
                          itemCount: history.length,
                          size: posterSize,
                          maxWidth: constraints.maxWidth,
                          landscape: landscape,
                          ratioOf: (i) {
                            final url = picUrl(history[i]);
                            return PosterRatioStore.instance.ratioOf(url) ??
                                (landscape ? 16 / 10 : 2 / 3);
                          },
                          onLayoutDone: (ctx) {
                            for (final item in history) {
                              probePosterRatio(
                                ctx,
                                picUrl(item),
                                app.findSource(item.sourceId)?.api,
                              );
                            }
                          },
                          itemBuilder: cardFor,
                        ),
                      );
                    }

                    final spec = vodGridSpec(
                      maxWidth: constraints.maxWidth,
                      size: posterSize,
                      landscape: landscape,
                    );
                    return GridView.builder(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                      gridDelegate: vodGridDelegate(
                        maxWidth: constraints.maxWidth,
                        size: posterSize,
                        landscape: landscape,
                      ),
                      itemCount: history.length,
                      itemBuilder: (context, i) => VodCell(
                        width: spec.width,
                        child: cardFor(context, i),
                      ),
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
