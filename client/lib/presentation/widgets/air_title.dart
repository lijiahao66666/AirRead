import 'package:flutter/foundation.dart' show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import '../../core/theme/app_colors.dart';

class AirTitle extends StatefulWidget {
  const AirTitle({super.key});

  @override
  State<AirTitle> createState() => _AirTitleState();
}

class _AirTitleState extends State<AirTitle> with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  bool _settled = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3200),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _controller.forward(from: 0).whenComplete(() {
        if (!mounted) return;
        setState(() {
          _settled = true;
        });
      });
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    final onSurface = scheme.onSurface;
    final baseA = isDark ? AppColors.neonCyan : AppColors.techBlue;
    final baseB = isDark ? AppColors.techBlue : AppColors.neonCyan;

    const titleText = '灵阅';

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final titleGradient = _settled
            ? LinearGradient(
                colors: [
                  baseA,
                  Color.lerp(baseA, baseB, 0.45) ?? baseA,
                  baseB,
                ],
                stops: const [0.0, 0.5, 1.0],
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
              )
            : () {
                final c = _controller.value;
                const w = 0.26;
                final s0 = (c - w).clamp(0.0, 1.0);
                final s1 = c.clamp(0.0, 1.0);
                final s2 = (c + w).clamp(0.0, 1.0);
                return LinearGradient(
                  colors: [
                    baseA,
                    Color.lerp(baseA, Colors.white, isDark ? 0.26 : 0.22) ??
                        baseA,
                    baseB,
                  ],
                  stops: [s0, s1, s2],
                  begin: Alignment.centerLeft,
                  end: Alignment.centerRight,
                );
              }();

        final titleStyle = TextStyle(
          fontFamily: defaultTargetPlatform == TargetPlatform.iOS
              ? 'PingFang SC'
              : null,
          fontFamilyFallback: const ['PingFang SC', 'HarmonyOS Sans SC', 'Noto Sans SC', 'Microsoft YaHei'],
          fontSize: 30,
          fontWeight: FontWeight.w800,
          letterSpacing: 2.0,
          height: 1.0,
          color: Colors.white,
        );

        final title = ShaderMask(
          shaderCallback: (bounds) => titleGradient.createShader(bounds),
          child: Text(titleText, style: titleStyle),
        );

        final strokeColor = (isDark ? Colors.black : Colors.white).withAlpha(40);
        final shadowColor = (isDark ? Colors.black : Colors.white).withAlpha(22);

        return RepaintBoundary(
          child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Stack(
              alignment: Alignment.center,
              children: [
                Text(
                  titleText,
                  style: titleStyle.copyWith(
                    foreground: Paint()
                      ..style = PaintingStyle.stroke
                      ..strokeWidth = 1.15
                      ..color = strokeColor,
                    shadows: [
                      Shadow(
                        color: shadowColor,
                        blurRadius: 10,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                ),
                title,
              ],
            ),
            const SizedBox(height: 2),
            Text(
              'AIR READ',
              style: TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w600,
                letterSpacing: 2.8,
                height: 1.0,
                color: onSurface.withAlpha(isDark ? 150 : 140),
              ),
            ),
          ],
          ),
        );
      },
    );
  }
}
