import 'package:flutter/material.dart';
import '../theme/app_palette.dart';

/// 应用品牌标识：直接复用桌面图标素材。
class BrandMark extends StatelessWidget {
  const BrandMark({super.key, this.size = 88});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(size * 0.22),
        boxShadow: [
          BoxShadow(
            color: const Color(0x557FA6FF),
            blurRadius: size * 0.32,
            spreadRadius: size * 0.01,
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Image.asset(
        'assets/branding/app_icon.png',
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => ColoredBox(
          color: context.palette.surfaceHigh,
          child: Icon(Icons.play_circle_outline, color: context.palette.textFaint),
        ),
      ),
    );
  }
}
