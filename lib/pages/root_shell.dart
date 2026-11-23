import 'package:flutter/material.dart';

import '../theme/app_palette.dart';
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
        bottomNavigationBar: _WeChatTabBar(
          index: _index,
          onTap: (value) => setState(() => _index = value),
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
              // 和手机端一致：不要选中胶囊，只靠图标/文字变色
              indicatorColor: Colors.transparent,
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

/// 微信风格底部标签栏：没有选中胶囊/背景色块，只靠图标与文字变色区分当前页。
class _WeChatTabBar extends StatelessWidget {
  const _WeChatTabBar({required this.index, required this.onTap});

  final int index;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final selectedColor = Theme.of(context).colorScheme.primary;
    final unselectedColor = palette.textSecondary;

    return Container(
      color: palette.surface,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: palette.border, width: 0.8)),
        ),
        child: SafeArea(
          top: false,
          child: SizedBox(
            height: 54,
            child: Row(
              children: [
                for (var i = 0; i < _RootShellState._dests.length; i++)
                  Expanded(
                    child: Material(
                      color: Colors.transparent,
                      child: InkWell(
                        onTap: () => onTap(i),
                        // 去掉水波纹之外的任何选中态装饰
                        splashFactory: NoSplash.splashFactory,
                        highlightColor: Colors.transparent,
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              i == index
                                  ? _RootShellState._dests[i].selectedIcon
                                  : _RootShellState._dests[i].icon,
                              size: 23,
                              color: i == index ? selectedColor : unselectedColor,
                            ),
                            const SizedBox(height: 2),
                            Text(
                              _RootShellState._dests[i].label,
                              style: TextStyle(
                                fontSize: 11,
                                height: 1.1,
                                color: i == index ? selectedColor : unselectedColor,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
