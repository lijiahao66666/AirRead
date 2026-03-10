import 'package:flutter/material.dart';

class AppColors {
  // Primary Palette
  static const Color airBlue = Color(0xFFE1F5FE);
  static const Color mistWhite = Color(0xFFF5F9FA);
  static const Color techBlue = Color(0xFF29B6F6);
  
  // Dark Mode / Text
  static const Color deepSpace = Color(0xFF263238);
  static const Color nightBg = Color(0xFF121212); // Deeper black for OLED
  
  // Accents & Effects
  static const Color neonCyan = Color(0xFF00E5FF);
  static const Color softGrey = Color(0xFFB0BEC5);
  
  // Gradients
  static const LinearGradient aiFlowGradient = LinearGradient(
    colors: [techBlue, neonCyan],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );
}
