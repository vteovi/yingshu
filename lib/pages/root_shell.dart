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

  /// 只有真正打开过的页才构建：一开始就把首页、收藏、历史、设置全建出来，
  /// 小屏手机上第一帧要做的活太多，点标签会出现「点了没反应」的卡顿感。
  final Set<int> _visited = {0};

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
    final railBlue = Theme.of(context).brightness == Brightness.dark
        ? const Color(0xFF4D8DFF)
        : const Color(0xFF2F6BFF);

    final pages = [
      const HomePage(),
      if (_visited.contains(1)) const FavoritesPage() else const SizedBox.shrink(),
      if (_visited.contains(2)) const HistoryPage() else const SizedBox.shrink(),
      if (_visited.contains(3)) const SettingsPage() else const SizedBox.shrink(),
    ];

    if (!wide) {
      return Scaffold(
        body: IndexedStack(index: _index, children: pages),
        bottomNavigationBar: _WeChatTabBar(
          index: _index,
          onTap: (value) {
            setState(() {
              _index = value;
              _visited.add(value);
            });
          },
        ),
      );
    }

    return Scaffold(
      body: Row(
        children: [
          // 侧边栏瘦身：收起的竖条 64（默认 72），展开状态 148（默认 180 太宽）
          SizedBox(
            width: extended ? 180 : 72,
            child: NavigationRail(
              selectedIndex: _index,
              extended: extended,
              labelType: extended ? NavigationRailLabelType.none : NavigationRailLabelType.all,
              // 宽度用 Material 默认值：之前收到 64 太窄，图标/文字的点击热区挤在一起，
              // 点边缘常常只出动画不切换。72 / 180 是踩过坑后的稳妥尺寸。
              minWidth: 72,
              minExtendedWidth: 180,
              // 和手机端一致：不要选中胶囊，只靠图标/文字变色
              indicatorColor: Colors.transparent,
              selectedIconTheme: IconThemeData(size: 22, color: railBlue),
              unselectedIconTheme: IconThemeData(size: 22, color: context.palette.textSecondary),
              selectedLabelTextStyle: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: railBlue,
              ),
              unselectedLabelTextStyle: TextStyle(
                fontSize: 12,
                color: context.palette.textSecondary,
              ),
              onDestinationSelected: (value) => setState(() {
                _index = value;
                _visited.add(value);
              }),
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
///
/// 老手机上「点几次点不中」的两个根因都在这里解决：
/// 1. 用 InkWell 的点击判定要「按下到抬起位移不超过 18dp」，电阻屏/低端触屏一抖
///    就被判成拖拽，tap 直接丢弃 —— 改成 Listener 监听 onPointerDown，
///    手指落下即切换，不再做位移判定，根本不给它误判的机会。
/// 2. 系统手势条所在的最底下一截是「看得见点不到」的死区 —— 现在每格自己承担
///    留白并且最少留 6dp，图标/文字整体抬高，手指落在最底部也不会只点到系统手势区。
class _WeChatTabBar extends StatefulWidget {
  const _WeChatTabBar({required this.index, required this.onTap});

  final int index;
  final ValueChanged<int> onTap;

  @override
  State<_WeChatTabBar> createState() => _WeChatTabBarState();
}

class _WeChatTabBarState extends State<_WeChatTabBar> {
  /// 当前按下高亮的格子；null 表示没有手指在上面。
  int? _pressedIndex;

  /// 正在跟踪的手指。多指同时按只认第一根，避免一次触摸切两次页。
  int? _activePointer;

  void _handleDown(int i, PointerDownEvent event) {
    if (_activePointer != null) return;
    _activePointer = event.pointer;
    setState(() => _pressedIndex = i);
    widget.onTap(i);
  }

  void _handleUp(PointerEvent event) {
    if (event.pointer != _activePointer) return;
    _activePointer = null;
    if (mounted) setState(() => _pressedIndex = null);
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // 不用 colorScheme.primary：深色主题里它被调得很浅（#7FA6FF），
    // 灰字→浅蓝看着像"变淡"而不是"变蓝"。这里直接给饱和蓝。
    final selectedColor = isDark ? const Color(0xFF4D8DFF) : const Color(0xFF2F6BFF);
    final unselectedColor = palette.textSecondary;
    final systemInset = MediaQuery.paddingOf(context).bottom;
    // 最少留 6dp：有些老机器的系统栏高度上报不准（给 0 或偏小），
    // 图标就会贴着物理底边，正好压在系统手势区内。
    final bottomInset = systemInset < 6 ? 6.0 : systemInset;

    return Container(
      color: palette.surface,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: palette.border, width: 0.8)),
        ),
        // 整条都是热区：留白放在每格内部，格子本身铺满整条高度。
        child: SizedBox(
          height: 54 + bottomInset,
          child: Row(
            children: [
              for (var i = 0; i < _RootShellState._dests.length; i++)
                Expanded(
                  child: Semantics(
                    button: true,
                    selected: i == widget.index,
                    label: _RootShellState._dests[i].label,
                    child: Listener(
                      // opaque：连留白那一段也算在自己的命中区域里
                      behavior: HitTestBehavior.opaque,
                      onPointerDown: (event) => _handleDown(i, event),
                      onPointerUp: _handleUp,
                      onPointerCancel: _handleUp,
                      child: Container(
                        color: _pressedIndex == i
                            ? selectedColor.withValues(alpha: 0.10)
                            : Colors.transparent,
                        padding: EdgeInsets.only(bottom: bottomInset),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              i == widget.index
                                  ? _RootShellState._dests[i].selectedIcon
                                  : _RootShellState._dests[i].icon,
                              size: 23,
                              color: i == widget.index ? selectedColor : unselectedColor,
                            ),
                            const SizedBox(height: 2),
                            Text(
                              _RootShellState._dests[i].label,
                              style: TextStyle(
                                fontSize: 11,
                                height: 1.1,
                                fontWeight:
                                    i == widget.index ? FontWeight.w600 : FontWeight.w400,
                                color: i == widget.index ? selectedColor : unselectedColor,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
