import 'package:flutter/material.dart';

import '../theme.dart';

/// A product photo from the shop, or a bag icon when there is none.
class ProductImage extends StatelessWidget {
  const ProductImage(this.url, {super.key, this.size = 64});

  final String url;
  final double size;

  @override
  Widget build(BuildContext context) {
    final icon = Icon(Icons.shopping_bag_outlined, color: AppColors.pine700, size: size * 0.45);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: AppColors.pine100, borderRadius: BorderRadius.circular(size * 0.22)),
      clipBehavior: Clip.antiAlias,
      alignment: Alignment.center,
      child: url.isEmpty ? icon : Image.network(url, fit: BoxFit.contain, errorBuilder: (_, __, ___) => icon),
    );
  }
}
