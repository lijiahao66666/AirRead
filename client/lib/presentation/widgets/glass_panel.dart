import 'dart:ui';

import 'package:flutter/material.dart';

import '../../core/theme/app_tokens.dart';

/// A lightweight glassmorphism container for sheets/panels.
///
/// - Uses BackdropFilter blur + high-opacity surface tint.
/// - Avoid overdoing blur/opacity: this app's base style is "airy reading".
class GlassPanel extends StatelessWidget {
  final Widget child;

  final BorderRadius borderRadius;
  final EdgeInsetsGeometry padding;

  /// The base surface color before applying [opacity].
  final Color? surfaceColor;

  /// Surface alpha applied to [surfaceColor].
  final double opacity;

  /// Backdrop blur strength.
  final double blurSigma;

  /// Optional border. If null, a subtle top border is used.
  final Border? border;

  /// Optional shadow.
  final List<BoxShadow>? boxShadow;

  const GlassPanel({
    super.key,
    required this.child,
    this.borderRadius = const BorderRadius.vertical(
      top: Radius.circular(AppTokens.radiusLg),
    ),
    this.padding = const EdgeInsets.all(0),
    this.surfaceColor,
    this.opacity = AppTokens.glassOpacity,
    this.blurSigma = AppTokens.glassBlurSigma,
    this.border,
    this.boxShadow,
  });

  factory GlassPanel.sheet({
    Key? key,
    required Widget child,
    EdgeInsetsGeometry padding = const EdgeInsets.all(0),
    Color? surfaceColor,
    double opacity = AppTokens.glassOpacity,
    double blurSigma = AppTokens.glassBlurSigma,
    BorderRadius borderRadius = const BorderRadius.vertical(
      top: Radius.circular(AppTokens.radiusLg),
    ),
  }) {
    return GlassPanel(
      key: key,
      padding: padding,
      surfaceColor: surfaceColor,
      opacity: opacity,
      blurSigma: blurSigma,
      borderRadius: borderRadius,
      boxShadow: AppTokens.shadowSoft,
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final base = surfaceColor ?? cs.surface;
    final onSurface = cs.onSurface;

    final effectiveBorder = border ??
        Border(
          top: BorderSide(
            color: onSurface.withOpacityCompat(AppTokens.borderOpacity),
            width: AppTokens.stroke,
          ),
        );

    // Skip expensive BackdropFilter when blur is disabled (blurSigma <= 0)
    if (blurSigma <= 0) {
      return Container(
        padding: padding,
        decoration: BoxDecoration(
          color: base.withOpacityCompat(opacity),
          borderRadius: borderRadius,
          border: effectiveBorder,
          boxShadow: boxShadow,
        ),
        child: child,
      );
    }

    return ClipRRect(
      borderRadius: borderRadius,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            color: base.withOpacityCompat(opacity),
            borderRadius: borderRadius,
            border: effectiveBorder,
            boxShadow: boxShadow,
          ),
          child: child,
        ),
      ),
    );
  }
}
