import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_tokens.dart';
import '../../presentation/providers/illustration_provider.dart';
import '../../ai/illustration/scene_card.dart';

class IllustrationPanel extends StatefulWidget {
  final bool isDark;
  final Color bgColor;
  final Color textColor;
  final String bookId;
  final String chapterId;
  final String chapterTitle;
  final String chapterContent;

  const IllustrationPanel({
    super.key,
    required this.isDark,
    required this.bgColor,
    required this.textColor,
    required this.bookId,
    required this.chapterId,
    required this.chapterTitle,
    required this.chapterContent,
  });

  @override
  State<IllustrationPanel> createState() => _IllustrationPanelState();
}

class _IllustrationPanelState extends State<IllustrationPanel> {
  bool _analyzing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final provider = context.read<IllustrationProvider>();
      final scenes = provider.getScenes(widget.chapterId);
      if (scenes.isEmpty) {
        _analyzeScenes();
      }
    });
  }

  Future<void> _analyzeScenes() async {
    if (_analyzing) return;
    setState(() => _analyzing = true);
    
    try {
      await context.read<IllustrationProvider>().analyzeChapter(
        chapterId: widget.chapterId,
        chapterTitle: widget.chapterTitle,
        content: widget.chapterContent,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('场景分析失败: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _analyzing = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // 保持与 QA 面板一致的背景色计算逻辑
    final Color cardBg = widget.isDark
        ? Colors.white.withOpacityCompat(0.07)
        : AppColors.mistWhite;

    return Consumer<IllustrationProvider>(
      builder: (context, provider, child) {
        final scenes = provider.getScenes(widget.chapterId);
        
        // 保持与 QA 面板一致的外层容器
        return Container(
          decoration: BoxDecoration(
            color: cardBg,
            borderRadius: BorderRadius.circular(AppTokens.radiusMd),
            border: Border.all(
              color: widget.textColor.withOpacityCompat(0.08),
              width: AppTokens.stroke,
            ),
          ),
          child: Column(
            children: [
              // 顶部操作栏
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 10),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '章节插画',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: widget.textColor,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            widget.chapterTitle,
                            style: TextStyle(
                              fontSize: 12,
                              color: widget.textColor.withOpacityCompat(0.6),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (_analyzing)
                      SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: widget.textColor.withOpacityCompat(0.5),
                        ),
                      )
                    else
                      IconButton(
                        icon: const Icon(Icons.refresh_rounded, size: 20),
                        tooltip: '重新分析场景',
                        onPressed: _analyzeScenes,
                        color: widget.textColor.withOpacityCompat(0.7),
                      ),
                  ],
                ),
              ),
              
              const Divider(height: 1),
              
              // 场景列表
              Expanded(
                child: scenes.isEmpty && _analyzing
                    ? const Center(child: Text('AI 正在分析精彩场景...'))
                    : scenes.isEmpty
                        ? Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.image_search_rounded,
                                  size: 48,
                                  color: widget.textColor.withOpacityCompat(0.2),
                                ),
                                const SizedBox(height: 12),
                                Text(
                                  '暂无场景灵感',
                                  style: TextStyle(
                                    color: widget.textColor.withOpacityCompat(0.4),
                                  ),
                                ),
                                const SizedBox(height: 16),
                                OutlinedButton.icon(
                                  onPressed: _analyzeScenes,
                                  icon: const Icon(Icons.auto_awesome),
                                  label: const Text('寻找灵感'),
                                  style: OutlinedButton.styleFrom(
                                    foregroundColor: AppColors.techBlue,
                                  ),
                                ),
                              ],
                            ),
                          )
                        : ListView.separated(
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                            itemCount: scenes.length,
                            separatorBuilder: (_, __) => const SizedBox(height: 16),
                            itemBuilder: (context, index) {
                              return _SceneCardWidget(
                                card: scenes[index],
                                isDark: widget.isDark,
                                textColor: widget.textColor,
                                onGenerate: () => provider.generateImage(widget.chapterId, scenes[index]),
                              );
                            },
                          ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _SceneCardWidget extends StatelessWidget {
  final SceneCard card;
  final bool isDark;
  final Color textColor;
  final VoidCallback onGenerate;

  const _SceneCardWidget({
    required this.card,
    required this.isDark,
    required this.textColor,
    required this.onGenerate,
  });

  @override
  Widget build(BuildContext context) {
    // 卡片背景稍微深一点，与面板背景区分
    final bg = isDark
        ? Colors.white.withOpacityCompat(0.05)
        : Colors.white;
    
    return Container(
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: textColor.withOpacityCompat(0.06),
          width: AppTokens.stroke,
        ),
        boxShadow: isDark ? [] : [
          BoxShadow(
            color: Colors.black.withOpacity(0.02),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 状态/图片区
          AspectRatio(
            aspectRatio: 16 / 9,
            child: _buildMediaArea(context),
          ),
          
          // 文本信息区
          Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        card.title,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                          color: textColor,
                        ),
                      ),
                    ),
                    if (card.status == SceneCardStatus.draft)
                      Padding(
                        padding: const EdgeInsets.only(left: 8),
                        child: TextButton.icon(
                          onPressed: onGenerate,
                          icon: const Icon(Icons.brush_rounded, size: 16),
                          label: const Text('生成'),
                          style: TextButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                            foregroundColor: AppColors.techBlue,
                            backgroundColor: AppColors.techBlue.withOpacityCompat(0.1),
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                            minimumSize: Size.zero,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  card.action,
                  style: TextStyle(
                    fontSize: 13,
                    color: textColor.withOpacityCompat(0.7),
                    height: 1.5,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    _Tag(text: card.mood, color: textColor),
                    if (card.visualAnchors.isNotEmpty)
                      _Tag(text: card.visualAnchors.split('、').first, color: textColor),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMediaArea(BuildContext context) {
    switch (card.status) {
      case SceneCardStatus.draft:
        return Container(
          color: textColor.withOpacityCompat(0.03),
          child: Stack(
            alignment: Alignment.center,
            children: [
              Icon(
                Icons.image_outlined,
                size: 48,
                color: textColor.withOpacityCompat(0.1),
              ),
              Positioned(
                bottom: 16,
                child: Text(
                  '点击生成预览画面',
                  style: TextStyle(
                    fontSize: 12,
                    color: textColor.withOpacityCompat(0.4),
                  ),
                ),
              ),
            ],
          ),
        );
        
      case SceneCardStatus.generating:
        return Container(
          color: textColor.withOpacityCompat(0.03),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: AppColors.techBlue,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'AI 正在绘图...',
                  style: TextStyle(
                    fontSize: 12,
                    color: textColor.withOpacityCompat(0.6),
                  ),
                ),
              ],
            ),
          ),
        );
        
      case SceneCardStatus.completed:
        if (card.localImagePath != null) {
          return GestureDetector(
            onTap: () {
              // TODO: 查看大图
            },
            child: Image.file(
              File(card.localImagePath!),
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => const Center(child: Icon(Icons.broken_image)),
            ),
          );
        }
        return const Center(child: Text('图片文件丢失'));
        
      case SceneCardStatus.failed:
        return Container(
          color: Colors.red.withOpacityCompat(0.05),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline, color: Colors.red, size: 32),
                const SizedBox(height: 8),
                Text(
                  '生成失败',
                  style: TextStyle(color: Colors.red.withOpacityCompat(0.8)),
                ),
                if (card.errorMsg != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Text(
                      card.errorMsg!,
                      style: const TextStyle(fontSize: 10, color: Colors.red),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: onGenerate,
                  child: const Text('重试'),
                ),
              ],
            ),
          ),
        );
    }
  }
}

class _Tag extends StatelessWidget {
  final String text;
  final Color color;

  const _Tag({required this.text, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacityCompat(0.05),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: color.withOpacityCompat(0.05),
          width: 0.5,
        ),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          color: color.withOpacityCompat(0.6),
        ),
      ),
    );
  }
}
