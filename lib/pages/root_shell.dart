import 'package:flutter/material.dart';

import 'favorites_page.dart';
import 'history_page.dart';
import 'home_page.dart';
import 'settings_page.dart';

/// 四个主入口，用 IndexedStack 保留各页状态。
///
/// 手机 / 窄屏：底部导航栏；
/// 平板 / 大屏（宽 ≥ 900dp）：导航栏改成左侧竖条，正文占满剩余宽度。
class RootShell extends StatefulWidget {
  const RootShell({super.key});

  @override
  State<RootShell> createState() => _RootShellState();
}

class _RootShellState extends State<RootShell> {
  int _index = 0;

  static const List<_Dest> _dests = [
    _Dest(Icons.home_outlined, Icons.home, '首页'),
    _Dest(Icons.favorite_border, Icons.favorite, '收藏'),
    _Dest(Icons.history, Icons.history, '历史'),
    _Dest(Icons.settings_outlined, Icons.settings, '设置'),
  ];

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final wide = width >= 900;
    final extended = width >= 1200;

    final pages = const [
      HomePage(),
      FavoritesPage(),
      HistoryPage(),
      SettingsPage(),
    ];

    if (!wide) {
      return Scaffold(
        body: IndexedStack(index: _index, children: pages),
        bottomNavigationBar: NavigationBar(
          // 默认 80 高，竖屏手机太占地方；收到 62 并同步缩小图标和文字
          height: 62,
          selectedIndex: _index,
          onDestinationSelected: (value) => setState(() => _index = value),
          destinations: [
            for (final dest in _dests)
              NavigationDestination(
                icon: Icon(dest.icon, size: 22),
                selectedIcon: Icon(dest.selectedIcon, size: 22),
                label: dest.label,
              ),
          ],
        ),
      );
    }

    return Scaffold(
      body: Row(
        children: [
          // 侧边栏瘦身：收起的竖条 64（默认 72），展开状态 148（默认 180 太宽）
          SizedBox(
            width: extended ? 148 : 64,
            child: NavigationRail(
              selectedIndex: _index,
              extended: extended,
              labelType: extended ? NavigationRailLabelType.none : NavigationRailLabelType.all,
              minWidth: 64,
              minExtendedWidth: 148,
              onDestinationSelected: (value) => setState(() => _index = value),
              destinations: [
                for (final dest in _dests)
                  NavigationRailDestination(
                    icon: Icon(dest.icon, size: 22),
                    selectedIcon: Icon(dest.selectedIcon, size: 22),
                    label: Text(dest.label),
                  ),
              ],
            ),
          ),
          const VerticalDivider(width: 1, thickness: 1),
          Expanded(child: IndexedStack(index: _index, children: pages)),
        ],
      ),
    );
  }
}

class _Dest {
  const _Dest(this.icon, this.selectedIcon, this.label);

  final IconData icon;
  final IconData selectedIcon;
  final String label;
}
