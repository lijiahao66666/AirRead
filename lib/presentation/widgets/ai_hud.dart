import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import 'glass_panel.dart';

enum AiHudFeature {
  translate,
  summarize,
  toImageText,
  readAloud,
  qa,
}

class AiHud extends StatelessWidget {
  final Color bgColor;
  final Color textColor;

  /// Which features are currently enabled/active. Used for icon highlight.
  final Set<AiHudFeature> activeFeatures;

  /// Main feature action.
  final ValueChanged<AiHudFeature>? onFeatureTap;

  /// Open AI settings center (single entry).
  final VoidCallback? onOpenSettings;

  const AiHud({
    super.key,
    this.bgColor = Colors.white,
    this.textColor = AppColors.deepSpace,
    this.activeFeatures = const {},
    this.onFeatureTap,
    this.onOpenSettings,
  });

  @override
  Widget build(BuildContext context) {
    return GlassPanel.sheet(
      surfaceColor: bgColor,
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
                'AI伴读',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: textColor,
                ),
              ),
              const Spacer(),
              if (onOpenSettings != null)
                IconButton(
                  icon: Icon(Icons.tune, color: textColor.withOpacity(0.7)),
                  onPressed: onOpenSettings,
                  tooltip: 'AI设置',
                ),
            ],
          ),
          const SizedBox(height: 24),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _buildFeatureBtn(
                context,
                icon: Icons.translate,
                label: '翻译',
                feature: AiHudFeature.translate,
              ),
              _buildFeatureBtn(
                context,
                icon: Icons.summarize,
                label: '总结',
                feature: AiHudFeature.summarize,
              ),
              _buildFeatureBtn(
                context,
                icon: Icons.image,
                label: '图文',
                feature: AiHudFeature.toImageText,
              ),
              _buildFeatureBtn(
                context,
                icon: Icons.volume_up,
                label: '朗读',
                feature: AiHudFeature.readAloud,
              ),
            ],
          ),
          const SizedBox(height: 32),
          Center(
            child: _buildFeatureBtn(
              context,
              icon: Icons.question_answer,
              label: '问答',
              feature: AiHudFeature.qa,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFeatureBtn(
    BuildContext context, {
    required IconData icon,
    required String label,
    required AiHudFeature feature,
  }) {
    final bool isDark = bgColor.computeLuminance() < 0.5;
    final Color btnBg = isDark ? Colors.white.withOpacity(0.1) : AppColors.mistWhite;

    final bool isActive = activeFeatures.contains(feature);

    // Subtle active style: keep neutral background, highlight via blue icon + ring + soft glow.
    final Color iconColor = isActive ? AppColors.techBlue : textColor;
    final Color labelColor = isActive ? AppColors.techBlue : textColor.withOpacity(0.7);

    final Border border = Border.all(
      color: isActive
          ? AppColors.techBlue.withOpacity(0.85)
          : textColor.withOpacity(0.06),
      width: isActive ? 1.5 : 1,
    );

    final List<BoxShadow> glow = isActive
        ? [
            BoxShadow(
              color: AppColors.techBlue.withOpacity(0.28),
              blurRadius: 16,
              spreadRadius: 1,
            ),
          ]
        : const [];

    return Column(
      children: [
        Container(
          width: 64,
          height: 64,
          decoration: BoxDecoration(
            color: btnBg,
            shape: BoxShape.circle,
            border: border,
            boxShadow: glow,
          ),
          child: IconButton(
            icon: Icon(icon, color: iconColor),
            onPressed: () => onFeatureTap?.call(feature),
            tooltip: label,
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          width: 72,
          child: Center(
            child: Text(
              label,
              style: TextStyle(
                color: labelColor,
                fontSize: 12,
                fontWeight: isActive ? FontWeight.w600 : FontWeight.w500,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
