import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../core/image_cache.dart';
import '../core/image_util.dart';
import '../models/vod.dart';
import '../theme/app_palette.dart';

/// 海报卡片：默认 2:3 竖版封面；[landscape] 打开时改成横版 16:10 封面（图上文下）。
class VodCard extends StatelessWidget {
  const VodCard({
    super.key,
    required this.vod,
    this.onTap,
    this.onLongPress,
    this.footer,
    this.showRemarks = true,
    this.apiBase,
    this.landscape = false,
  });

  final VodItem vod;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// 卡片底部补充信息（例如搜索结果的来源名）。
  final String? footer;
  final bool showRemarks;

  /// 当前订阅源的接口地址，用于补全相对海报地址与生成 Referer 请求头。
  final String? apiBase;

  /// 横版卡片：封面按 16:10 展示，文字压在下面两行。
  final bool landscape;

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
                  _Poster(pic: vod.pic, name: vod.name, apiBase: apiBase),
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
            maxLines: landscape ? 1 : 2,
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
            )
          else if (landscape && vod.remarks.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text(
                vod.remarks,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: context.palette.textFaint),
              ),
            ),
        ],
      ),
    );
  }
}

class _Poster extends StatelessWidget {
  const _Poster({required this.pic, required this.name, this.apiBase});

  final String pic;
  final String name;
  final String? apiBase;

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

    final url = normalizeImageUrl(pic, api: apiBase);
    if (url.isEmpty) return placeholder;
    // 用 ImageProvider 而不是 CachedNetworkImage：解码结果会进 Flutter 内存缓存，
    // 切标签/返回上一页时同一张海报直接命中，不会先闪一下空白再淡入。
    return Image(
      image: CachedNetworkImageProvider(
        url,
        cacheManager: PosterCacheManager.instance,
        headers: imageHeadersFor(apiBase),
        maxWidth: 480,
      ),
      fit: BoxFit.cover,
      gaplessPlayback: true,
      filterQuality: FilterQuality.low,
      errorBuilder: (_, __, ___) => placeholder,
    );
  }
}
