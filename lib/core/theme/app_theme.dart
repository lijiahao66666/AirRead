import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'app_colors.dart';

class AppTheme {
  static ThemeData get lightTheme {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      colorScheme: ColorScheme.fromSeed(
        seedColor: AppColors.airBlue,
        primary: AppColors.techBlue,
        surface: AppColors.mistWhite,
        background: AppColors.airBlue,
        onSurface: AppColors.deepSpace,
      ),
      scaffoldBackgroundColor: AppColors.mistWhite,
      textTheme: GoogleFonts.interTextTheme().apply(
        bodyColor: AppColors.deepSpace,
        displayColor: AppColors.deepSpace,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        titleTextStyle: GoogleFonts.montserrat(
          color: AppColors.deepSpace,
          fontSize: 24,
          fontWeight: FontWeight.w200, // Extra Light for "Air" feel
          letterSpacing: 4.0, // Wide spacing for elegance
        ),
      ),
    );
  }

  static ThemeData get darkTheme {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: ColorScheme.fromSeed(
        seedColor: AppColors.deepSpace,
        primary: AppColors.techBlue,
        surface: const Color(0xFF1E272C),
        background: AppColors.nightBg,
        onSurface: AppColors.mistWhite,
        brightness: Brightness.dark,
      ),
      scaffoldBackgroundColor: AppColors.nightBg,
      textTheme: GoogleFonts.interTextTheme(ThemeData.dark().textTheme).apply(
        bodyColor: AppColors.mistWhite,
        displayColor: AppColors.mistWhite,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        titleTextStyle: GoogleFonts.montserrat(
          color: AppColors.mistWhite,
          fontSize: 24,
          fontWeight: FontWeight.w200,
          letterSpacing: 4.0,
        ),
      ),
    );
  }

  /// Returns theme based on current system mode
  static ThemeData getTheme(BuildContext context) {
    // Check system brightness directly instead of relying on cached state
    final brightness = MediaQuery.platformBrightnessOf(context);
    
    return brightness == Brightness.dark ? darkTheme : lightTheme;
  }
}
