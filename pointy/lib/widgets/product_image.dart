import 'package:flutter/material.dart';

import '../theme.dart';

/// A product photo from the shop, or a bag icon when there is none.
class ProductImage extends StatelessWidget {
  const ProductImage(this.url, {super.key, this.size = 64, this.width, this.radius});

  final String url;
  final double size;

  /// Wider than tall (a product card's banner); square when null.
  final double? width;
  final double? radius;

  @override
  Widget build(BuildContext context) {
    final icon = Icon(Icons.shopping_bag_outlined, color: AppColors.pine700, size: size * (width == null ? 0.45 : 0.33));
    return Container(
      width: width ?? size,
      height: size,
      decoration: BoxDecoration(color: AppColors.pine100, borderRadius: BorderRadius.circular(radius ?? size * 0.22)),
      clipBehavior: Clip.antiAlias,
      alignment: Alignment.center,
      child: url.isEmpty ? icon : Image.network(url, fit: BoxFit.contain, errorBuilder: (_, __, ___) => icon),
    );
  }
}
