import 'package:flutter/material.dart';
import 'dart:math';
import '../../data/models/book.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_tokens.dart';
import 'local_file_image.dart'
    if (dart.library.js_interop) 'local_file_image_web.dart';

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
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    return GestureDetector(
      onTap: widget.onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Fixed aspect ratio for cover image
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: scheme.surface,
                borderRadius: BorderRadius.circular(AppTokens.radiusMd),
                border: Border.all(
                  color: scheme.onSurface.withOpacityCompat(isDark ? 0.16 : 0.06),
                  width: AppTokens.stroke,
                ),
                boxShadow: isDark ? null : AppTokens.shadowTight,
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
                            color: widget.isSelected
                                ? AppColors.techBlue
                                : scheme.surface.withOpacityCompat(0.82),
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: widget.isSelected
                                  ? AppColors.techBlue
                                  : scheme.onSurface.withOpacityCompat(0.28),
                              width: 1.5,
                            ),
                            boxShadow: [
                              if (!widget.isSelected)
                                BoxShadow(
                                  color: Colors.black.withOpacityCompat(
                                      isDark ? 0.24 : 0.10),
                                  blurRadius: 4,
                                  offset: const Offset(0, 2),
                                )
                            ],
                          ),
                          child: widget.isSelected
                              ? const Icon(Icons.check,
                                  size: 14, color: Colors.white)
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
          Builder(
            builder: (context) {
              final author = widget.book.author.trim();
              final isUnknown =
                  author.isEmpty || author.toLowerCase() == 'unknown';
              final style = Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurface.withOpacityCompat(0.55),
                  );
              final reservedHeight = (style?.fontSize ?? 12) *
                      ((style?.height ?? 1.25).clamp(1.0, 2.0)).toDouble() +
                  4;
              return SizedBox(
                height: reservedHeight,
                child: isUnknown
                    ? null
                    : Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          author,
                          style: style,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
              );
            },
          ),
          const SizedBox(height: 8),
          LinearProgressIndicator(
            value: widget.book.percentage,
            backgroundColor: scheme.onSurface.withOpacityCompat(isDark ? 0.16 : 0.08),
            valueColor: AlwaysStoppedAnimation<Color>(
              widget.book.percentage > 0
                  ? AppColors.techBlue
                  : Colors.transparent,
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
                final String percent =
                    (ratio * 100).clamp(0, 100).toStringAsFixed(0);
                return Text(
                  '$percent%',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurface.withOpacityCompat(0.55),
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
      final image = buildLocalFileImage(
        path: widget.book.coverPath,
        fit: BoxFit.cover,
        width: double.infinity,
        height: double.infinity,
        errorBuilder: (context, error, stackTrace) => _buildPlaceholder(),
      );
      if (image != null) return image;
    }

    return _buildPlaceholder();
  }

  Widget _buildPlaceholder() {
    final int seed = widget.book.id.hashCode ^ widget.book.title.hashCode;
    final random = Random(seed);
    final double hueA = (seed.abs() % 360).toDouble();
    final double hueB = ((hueA + 48 + (seed.abs() % 24)) % 360).toDouble();

    final Color a = HSLColor.fromAHSL(1, hueA, 0.55, 0.82).toColor();
    final Color b = HSLColor.fromAHSL(1, hueB, 0.58, 0.74).toColor();
    final Color c =
        HSLColor.fromAHSL(1, (hueA + 120) % 360, 0.40, 0.90).toColor();

    final begin = random.nextBool() ? Alignment.topLeft : Alignment.topRight;
    final end =
        random.nextBool() ? Alignment.bottomRight : Alignment.bottomLeft;
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [a, b, c],
          stops: const [0.0, 0.55, 1.0],
          begin: begin,
          end: end,
        ),
      ),
      width: double.infinity,
      height: double.infinity,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Positioned(
            left: -40,
            top: -40,
            child: Container(
              width: 140,
              height: 140,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white.withOpacityCompat(0.18),
              ),
            ),
          ),
          Positioned(
            right: -60,
            bottom: -60,
            child: Container(
              width: 180,
              height: 180,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white.withOpacityCompat(0.12),
              ),
            ),
          ),
          Center(
            child: Icon(
              Icons.book_outlined,
              size: 48,
              color: Colors.white.withOpacityCompat(0.85),
            ),
          ),
        ],
      ),
    );
  }
}
