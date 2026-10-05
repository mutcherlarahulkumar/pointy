import 'package:flutter/material.dart';

import '../theme.dart';

/// An icon on a soft pine square, used in lists and action rows.
class TileIcon extends StatelessWidget {
  const TileIcon(this.icon, {super.key, this.size = 40, Color? background, Color? color})
      : _background = background,
        _color = color;

  final IconData icon;
  final double size;
  final Color? _background, _color;
  Color get background => _background ?? AppColors.pine100;
  Color get color => _color ?? AppColors.pine700;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: background, borderRadius: BorderRadius.circular(size / 3.5)),
      child: Icon(icon, color: color, size: size * 0.5),
    );
  }
}

/// The icon used for a spending category.
IconData categoryIcon(String category) => switch (category) {
      'food' => Icons.restaurant_outlined,
      'stay' => Icons.hotel_outlined,
      'transport' => Icons.directions_car_outlined,
      _ => Icons.shopping_bag_outlined,
    };
