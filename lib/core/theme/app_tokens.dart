import 'package:flutter/material.dart';

/// Shared visual tokens used across Reader/Bookshelf to keep UI consistent.
///
/// Keep these values small and composable. Prefer reusing them instead of
/// hardcoding radii/blur/opacity in widgets.
class AppTokens {
  // Radius
  static const double radiusXs = 8;
  static const double radiusSm = 12;
  static const double radiusMd = 16;
  static const double radiusLg = 24;

  // Stroke / border
  static const double strokeHairline = 0.8;
  static const double stroke = 1.0;

  // Glass panel
  static const double glassBlurSigma = 10;
  static const double glassOpacity = 0.94;
  static const double glassOpacityDense = 0.96;

  // Opacities
  static const double borderOpacity = 0.10;
  static const double dividerOpacity = 0.08;
  static const double hintOpacity = 0.55;

  // Shadows (soft, low-contrast)
  static const List<BoxShadow> shadowSoft = [
    BoxShadow(
      color: Color(0x14000000),
      blurRadius: 18,
      offset: Offset(0, 10),
    ),
  ];

  static const List<BoxShadow> shadowTight = [
    BoxShadow(
      color: Color(0x12000000),
      blurRadius: 10,
      offset: Offset(0, 6),
    ),
  ];
}
