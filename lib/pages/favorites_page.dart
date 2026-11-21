import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/media_record.dart';
import '../models/vod.dart';
import '../state/app_state.dart';
import '../widgets/state_views.dart';
import '../widgets/vod_card.dart';
import 'detail_page.dart';

class FavoritesPage extends StatelessWidget {
  const FavoritesPage({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final favorites = app.favorites;

    return Scaffold(
      appBar: AppBar(
        title: const Text('收藏'),
        actions: [
          if (favorites.isNotEmpty)
            PopupMenuButton<String>(
              onSelected: (_) => _confirmClear(context, app),
              itemBuilder: (context) => const [
                PopupMenuItem(value: 'clear', child: Text('清空收藏')),
              ],
            ),
        ],
      ),
      body: favorites.isEmpty
          ? const EmptyView(
              icon: Icons.favorite_border,
              title: '还没有收藏',
              subtitle: '在影片详情页点击心形按钮即可收藏。',
            )
          : LayoutBuilder(
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

                return GridView.builder(
                  padding: const EdgeInsets.fromLTRB(horizontalPadding, 12, horizontalPadding, 24),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: crossAxisCount,
                    mainAxisSpacing: 16,
                    crossAxisSpacing: spacing,
                    mainAxisExtent: itemWidth * 1.5 + 52,
                  ),
                  itemCount: favorites.length,
                  itemBuilder: (context, i) {
                    final item = favorites[i];
                    return VodCard(
                      vod: VodItem(
                        vodId: item.vodId,
                        name: item.name,
                        pic: item.pic,
                        remarks: item.remarks,
                      ),
                      footer: item.sourceName,
                      onTap: () => _openDetail(context, app, item),
                      onLongPress: () => _confirmRemove(context, app, item),
                    );
                  },
                );
              },
            ),
    );
  }

  void _openDetail(BuildContext context, AppState app, FavoriteItem item) {
    final source = app.findSource(item.sourceId);
    if (source == null) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('这条收藏所属的订阅源已被删除')));
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => DetailPage(
          source: source,
          vodId: item.vodId,
          initialName: item.name,
          initialPic: item.pic,
        ),
      ),
    );
  }

  Future<void> _confirmRemove(BuildContext context, AppState app, FavoriteItem item) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('取消收藏'),
        content: Text('确定要取消收藏《${item.name}》吗？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('取消收藏')),
        ],
      ),
    );
    if (ok == true) {
      await app.removeFavorite(item);
    }
  }

  Future<void> _confirmClear(BuildContext context, AppState app) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清空收藏'),
        content: const Text('所有收藏都会被删除，且无法恢复。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('清空')),
        ],
      ),
    );
    if (ok == true) await app.clearFavorites();
  }
}
