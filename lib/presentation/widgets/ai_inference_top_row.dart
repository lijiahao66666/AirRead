import 'dart:io';
import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_tokens.dart';
import '../models/ai_chat_model_choice.dart';

class AiInferenceTopRow extends StatelessWidget {
  final bool isDark;
  final Color textColor;
  final AiChatModelChoice modelChoice;
  final bool local05Installed;
  final bool localMiniInstalled;
  final bool local18Installed;
  final Future<void> Function(AiChatModelChoice) onModelChoiceChanged;
  final bool thinkingEnabled;
  final Future<void> Function(bool) onThinkingChanged;
  final bool thinkingSupported;
  final bool enabled;

  const AiInferenceTopRow({
    super.key,
    required this.isDark,
    required this.textColor,
    required this.modelChoice,
    required this.local05Installed,
    required this.localMiniInstalled,
    required this.local18Installed,
    required this.onModelChoiceChanged,
    required this.thinkingEnabled,
    required this.onThinkingChanged,
    required this.thinkingSupported,
    this.enabled = true,
  });

  String _labelFor(AiChatModelChoice value) {
    return switch (value) {
      AiChatModelChoice.onlineHunyuan => '在线（混元）',
      AiChatModelChoice.localHunyuan05b =>
        local05Installed ? '本地（Hunyuan-0.5B）' : '本地（Hunyuan-0.5B 未下载）',
      AiChatModelChoice.localMiniCpm05b =>
        localMiniInstalled ? '本地（MiniCPM4-0.5B）' : '本地（MiniCPM4-0.5B 未下载）',
      AiChatModelChoice.localHunyuan18b =>
        local18Installed ? '本地（Hunyuan-1.8B）' : '本地（Hunyuan-1.8B 未下载）',
    };
  }

  @override
  Widget build(BuildContext context) {
    final bg = isDark ? Colors.white.withOpacityCompat(0.06) : Colors.white;
    final border = Border.all(
      color: textColor.withOpacityCompat(0.08),
      width: AppTokens.stroke,
    );
    final dropdownBg =
        isDark ? Colors.white.withOpacityCompat(0.04) : AppColors.mistWhite;
    final options = AiChatModelChoice.values.where((v) {
      if (Platform.isIOS) {
        if (v == AiChatModelChoice.localHunyuan18b ||
            v == AiChatModelChoice.localMiniCpm05b) {
          return false;
        }
      }
      return true;
    }).toList();

    return Row(
      children: [
        Expanded(
          child: Container(
            height: 38,
            decoration: BoxDecoration(
              color: dropdownBg,
              borderRadius: BorderRadius.circular(12),
              border: border,
            ),
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<AiChatModelChoice>(
                value: modelChoice,
                isExpanded: true,
                icon: Icon(Icons.keyboard_arrow_down_rounded,
                    color: textColor.withOpacityCompat(0.7)),
                dropdownColor: bg,
                style: TextStyle(
                  color: textColor.withOpacityCompat(0.9),
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
                items: options.map(
                  (v) {
                    final enabled = switch (v) {
                      AiChatModelChoice.localHunyuan05b => local05Installed,
                      AiChatModelChoice.localMiniCpm05b => localMiniInstalled,
                      AiChatModelChoice.localHunyuan18b => local18Installed,
                      _ => true,
                    };
                    final color = enabled
                        ? textColor.withOpacityCompat(0.9)
                        : textColor.withOpacityCompat(0.35);
                    return DropdownMenuItem(
                      value: v,
                      enabled: enabled,
                      child: Text(
                        _labelFor(v),
                        style: TextStyle(color: color),
                      ),
                    );
                  },
                ).toList(),
                onChanged: !enabled
                    ? null
                    : (v) {
                        if (v == null) return;
                        final selectable = switch (v) {
                          AiChatModelChoice.localHunyuan05b => local05Installed,
                          AiChatModelChoice.localMiniCpm05b =>
                            localMiniInstalled,
                          AiChatModelChoice.localHunyuan18b => local18Installed,
                          _ => true,
                        };
                        if (!selectable) return;
                        onModelChoiceChanged(v);
                      },
              ),
            ),
          ),
        ),
        const SizedBox(width: 10),
        FilterChip(
          label: const Text('深度思考'),
          selected: thinkingEnabled && thinkingSupported,
          onSelected: (!enabled || !thinkingSupported)
              ? null
              : (v) => onThinkingChanged(v),
          selectedColor: AppColors.techBlue.withOpacityCompat(0.16),
          side: BorderSide(
            color: thinkingEnabled && thinkingSupported
                ? AppColors.techBlue.withOpacityCompat(0.55)
                : textColor.withOpacityCompat(0.12),
            width: AppTokens.stroke,
          ),
          labelStyle: TextStyle(
            color: thinkingEnabled && thinkingSupported
                ? AppColors.techBlue
                : textColor.withOpacityCompat(
                    thinkingSupported ? 0.75 : 0.35,
                  ),
            fontWeight: FontWeight.w700,
            fontSize: 13,
          ),
          backgroundColor: dropdownBg,
          checkmarkColor: AppColors.techBlue,
          showCheckmark: false,
        ),
      ],
    );
  }
}
