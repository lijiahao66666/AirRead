import 'package:flutter/material.dart';
import '../../core/theme/app_colors.dart';

class AirTitle extends StatelessWidget {
  const AirTitle({super.key});

  @override
  Widget build(BuildContext context) {
    return ShaderMask(
      shaderCallback: (bounds) => const LinearGradient(
        colors: [AppColors.deepSpace, AppColors.techBlue],
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
      ).createShader(bounds),
      child: const Text(
        '灵阅',
        style: TextStyle(
          fontSize: 28,
          fontWeight: FontWeight.w600,
          color: Colors.white, // Required for ShaderMask
          letterSpacing: 4.0,
        ),
      ),
    );
  }
}
