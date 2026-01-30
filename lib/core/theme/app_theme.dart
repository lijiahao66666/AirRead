  /// Returns theme based on current system mode
  static ThemeData getTheme(BuildContext context) {
    // Check system brightness directly instead of relying on cached state
    final brightness = MediaQuery.platformBrightnessOf(context);
    
    return brightness == Brightness.dark ? getDarkTheme() : getLightTheme();
  }
}
