import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../models/vod.dart';
import '../theme/app_palette.dart';

/// 海报卡片：2:3 封面 + 备注角标 + 片名。
class VodCard extends StatelessWidget {
  const VodCard({
    super.key,
    required this.vod,
    this.onTap,
    this.onLongPress,
    this.footer,
    this.showRemarks = true,
  });

  final VodItem vod;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// 卡片底部补充信息（例如搜索结果的来源名）。
  final String? footer;
  final bool showRemarks;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      onLongPress: onLongPress,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _Poster(pic: vod.pic, name: vod.name),
                  if (showRemarks && vod.remarks.isNotEmpty)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: Container(
                        padding: const EdgeInsets.fromLTRB(8, 14, 8, 6),
                        decoration: const BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [Colors.transparent, Color(0xCC000000)],
                          ),
                        ),
                        child: Text(
                          vod.remarks,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11,
                            color: context.palette.textPrimary,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            vod.name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 13,
              height: 1.25,
              fontWeight: FontWeight.w500,
              color: context.palette.textPrimary,
            ),
          ),
          if (footer != null && footer!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text(
                footer!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: theme.colorScheme.secondary),
              ),
            ),
        ],
      ),
    );
  }
}

class _Poster extends StatelessWidget {
  const _Poster({required this.pic, required this.name});

  final String pic;
  final String name;

  @override
  Widget build(BuildContext context) {
    final placeholder = Container(
      color: context.palette.surfaceHigh,
      alignment: Alignment.center,
      child: Text(
        name.isEmpty ? '无海报' : name.substring(0, 1),
        style: TextStyle(fontSize: 26, color: context.palette.textFaint, fontWeight: FontWeight.w700),
      ),
    );

    if (pic.isEmpty) return placeholder;
    return CachedNetworkImage(
      imageUrl: pic,
      fit: BoxFit.cover,
      fadeInDuration: const Duration(milliseconds: 200),
      placeholder: (_, __) => ColoredBox(color: context.palette.surfaceHigh),
      errorWidget: (_, __, ___) => placeholder,
    );
  }
}
