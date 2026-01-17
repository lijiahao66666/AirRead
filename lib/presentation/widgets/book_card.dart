import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'dart:io';
import '../../data/models/book.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_tokens.dart';

class BookCard extends StatefulWidget {
  final Book book;
  final VoidCallback onTap;
  final int itemIndex;
  final int totalColumns;
  final double childAspectRatio;
  
  // Selection Control
  final bool isSelectionMode;
  final bool isSelected;
  final VoidCallback? onSelectionToggle;

  const BookCard({
    super.key,
    required this.book,
    required this.onTap,
    this.itemIndex = 0,
    this.totalColumns = 3,
    this.childAspectRatio = 0.65,
    this.isSelectionMode = false,
    this.isSelected = false,
    this.onSelectionToggle,
  });

  @override
  State<BookCard> createState() => _BookCardState();
}

class _BookCardState extends State<BookCard> {
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Fixed aspect ratio for cover image
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(AppTokens.radiusMd),
                border: Border.all(
                  color: AppColors.deepSpace.withOpacity(0.06),
                  width: AppTokens.stroke,
                ),
                boxShadow: AppTokens.shadowTight,
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(AppTokens.radiusMd),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    _buildCoverImage(),
                    // Selection Overlay (WeChat Style: Bottom-Right Circle)
                    if (widget.isSelectionMode)
                      Positioned(
                        bottom: 8,
                        right: 8,
                        child: Container(
                          width: 22,
                          height: 22,
                          decoration: BoxDecoration(
                            color: widget.isSelected ? AppColors.techBlue : Colors.white.withOpacity(0.8),
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: widget.isSelected ? AppColors.techBlue : Colors.grey.withOpacity(0.6),
                              width: 1.5,
                            ),
                            boxShadow: [
                              if (!widget.isSelected)
                                BoxShadow(
                                  color: Colors.black.withOpacity(0.1),
                                  blurRadius: 4,
                                  offset: const Offset(0, 2),
                                )
                            ],
                          ),
                          child: widget.isSelected 
                              ? const Icon(Icons.check, size: 14, color: Colors.white)
                              : null,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            widget.book.title,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 4),
          Text(
            widget.book.author,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: AppColors.softGrey,
                ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 8),
          LinearProgressIndicator(
            value: widget.book.percentage,
            backgroundColor: AppColors.mistWhite,
            valueColor: AlwaysStoppedAnimation<Color>(
              widget.book.percentage > 0 ? AppColors.techBlue : Colors.transparent,
            ),
            borderRadius: BorderRadius.circular(2),
            minHeight: 2,
          ),
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerRight,
            child: Builder(
              builder: (context) {
                final total = widget.book.totalPages;
                final current = widget.book.currentPage;
                if (total <= 0) {
                  return const SizedBox.shrink();
                }
                if (current <= 0) {
                  return const SizedBox.shrink();
                }
                final double ratio = current / total;
                final String percent = (ratio * 100).clamp(0, 100).toStringAsFixed(0);
                return Text(
                  '$percent%',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: AppColors.softGrey,
                        fontSize: 10,
                      ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCoverImage() {
    if (widget.book.coverBytes != null) {
      return Image.memory(
        widget.book.coverBytes!,
        fit: BoxFit.cover,
        width: double.infinity,
        height: double.infinity,
        errorBuilder: (context, error, stackTrace) => _buildPlaceholder(),
      );
    }
    
    if (widget.book.coverPath.isNotEmpty) {
      if (kIsWeb) return _buildPlaceholder();
      return Image.file(
        File(widget.book.coverPath),
        fit: BoxFit.cover,
        width: double.infinity,
        height: double.infinity,
        errorBuilder: (context, error, stackTrace) => _buildPlaceholder(),
      );
    }

    return _buildPlaceholder();
  }

  Widget _buildPlaceholder() {
    return Container(
      color: AppColors.mistWhite,
      width: double.infinity,
      height: double.infinity,
      child: Center(
        child: Icon(
          Icons.book_outlined,
          size: 48,
          color: AppColors.techBlue.withOpacity(0.3),
        ),
      ),
    );
  }
}
