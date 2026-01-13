import 'dart:ui';
import 'package:flutter/material.dart';
import '../../core/theme/app_colors.dart';

class AiHud extends StatelessWidget {
  final Color bgColor;
  final Color textColor;
  
  const AiHud({
    super.key, 
    this.bgColor = Colors.white, 
    this.textColor = AppColors.deepSpace
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: Container(
          decoration: BoxDecoration(
            color: bgColor.withOpacity(0.95), // Use passed bg color
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
            border: Border(
              top: BorderSide(color: textColor.withOpacity(0.1)),
            ),
          ),
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.auto_awesome, color: AppColors.techBlue),
                  const SizedBox(width: 8),
                  Text(
                    "AI伴读",
                    style: TextStyle(
                      fontSize: 16, // Unified font size 16pt
                      fontWeight: FontWeight.bold,
                      color: textColor, // Unified text color
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _buildFeatureBtn(context, Icons.translate, "即时翻译"),
                  _buildFeatureBtn(context, Icons.summarize, "内容摘要"),
                  _buildFeatureBtn(context, Icons.image, "转图文"),
                  _buildFeatureBtn(context, Icons.volume_up, "朗读"),
                ],
              ),
              const SizedBox(height: 32),
              Center(
                child: _buildFeatureBtn(context, Icons.question_answer, "智能问答"),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFeatureBtn(BuildContext context, IconData icon, String label) {
    // Button bg should be slightly different from panel bg
    // If dark mode, button bg lighter; if light mode, button bg slightly darker
    bool isDark = bgColor.computeLuminance() < 0.5;
    Color btnBg = isDark ? Colors.white.withOpacity(0.1) : AppColors.mistWhite;
    
    return Column(
      children: [
        Container(
          width: 64,
          height: 64,
          decoration: BoxDecoration(
            color: btnBg,
            shape: BoxShape.circle,
            // No shadow in dark mode for cleaner look? Or keep it.
          ),
          child: IconButton(
            icon: Icon(icon, color: textColor), // Icon matches text color
            onPressed: () {},
          ),
        ),
        const SizedBox(height: 8),
        Text(
          label,
          style: TextStyle(
            color: textColor.withOpacity(0.7),
            fontSize: 12,
          ),
        ),
      ],
    );
  }
}
