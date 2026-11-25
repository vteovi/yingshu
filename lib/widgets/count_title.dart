import 'package:flutter/material.dart';

import '../theme/app_palette.dart';

/// 带数量的标题：标题文字后面挂一个小胶囊，显示当前条目条数。
///
/// 收藏 / 历史这类列表页用它，用户一眼就知道自己攒了多少。
class CountTitle extends StatelessWidget {
  const CountTitle({
    super.key,
    required this.title,
    required this.count,
    this.unit = '条',
  });

  final String title;
  final int count;
  final String unit;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
        const SizedBox(width: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
            color: palette.surfaceHigh,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: palette.border),
          ),
          child: Text(
            '$count $unit',
            style: TextStyle(fontSize: 11, height: 1.2, color: palette.textSecondary),
          ),
        ),
      ],
    );
  }
}
