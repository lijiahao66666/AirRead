import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
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
      child: Text(
        'AirRead',
        style: GoogleFonts.righteous(
          fontSize: 28,
          fontWeight: FontWeight.w500,
          color: Colors.white, // Required for ShaderMask
          letterSpacing: 1.5,
        ),
      ),
    );
  }
}
