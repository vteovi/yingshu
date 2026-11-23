import 'package:flutter/material.dart';

import '../data/cms_api.dart';
import '../models/cms_source.dart';
import '../theme/app_palette.dart';
import '../widgets/vod_grid.dart';

/// 分类列表页：分页无限加载。首页已支持原地切换分类，这里保留深链入口。
class CategoryPage extends StatelessWidget {
  const CategoryPage({super.key, required this.source, required this.category});

  final CmsSource source;
  final CmsCategory category;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(category.typeName),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Center(
              child: Text(
                source.name,
                style: TextStyle(fontSize: 12, color: context.palette.textFaint),
              ),
            ),
          ),
        ],
      ),
      body: VodPagedGrid(source: source, typeId: category.typeId),
    );
  }
}
