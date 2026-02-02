import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:provider/provider.dart';
import '../../providers/books_provider.dart';
import '../../widgets/book_card.dart';
import '../../widgets/air_title.dart';
import '../../widgets/glass_panel.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_tokens.dart';
import '../reader/reader_page.dart';
import '../../../data/models/book.dart';

class BookshelfPage extends StatefulWidget {
  const BookshelfPage({super.key});

  @override
  State<BookshelfPage> createState() => _BookshelfPageState();
}

class _BookshelfPageState extends State<BookshelfPage> {
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    // System UI mode handled globally in main.dart to ensure consistency
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _handleImport(BuildContext context) async {
    final booksProvider = Provider.of<BooksProvider>(context, listen: false);

    if (kIsWeb) {
      try {
        final result = await FilePicker.platform.pickFiles(
          type: FileType.custom,
          allowedExtensions: ['epub', 'txt'],
          allowMultiple: true,
          withData: true,
        );
        if (result != null) {
          await booksProvider.importWebFiles(result);
        }
      } catch (e) {
        debugPrint('Error picking files on web: $e');
      }
    } else {
      await booksProvider.importBooks();
    }
  }

  void _onSearchChanged(String value) {
    setState(() {
      _searchQuery = value.toLowerCase();
    });
  }

  List<Book> _filterBooks(List<Book> books) {
    if (_searchQuery.isEmpty) return books;
    return books.where((book) {
      return book.title.toLowerCase().contains(_searchQuery) ||
          book.author.toLowerCase().contains(_searchQuery);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final booksProvider = Provider.of<BooksProvider>(context);
    // Filter books based on search query
    final displayBooks = _filterBooks(booksProvider.books);

    return Scaffold(
      extendBodyBehindAppBar: true,
      resizeToAvoidBottomInset:
          false, // Prevent keyboard/system UI from resizing layout
      appBar: AppBar(
        systemOverlayStyle: const SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          systemNavigationBarColor: Colors.transparent,
          statusBarIconBrightness: Brightness.dark,
          systemNavigationBarIconBrightness: Brightness.dark,
          systemNavigationBarContrastEnforced: false,
        ),
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        title: const AirTitle(),
        automaticallyImplyLeading: false,
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          // Responsive Grid Calculation
          final double screenWidth = constraints.maxWidth;
          int crossAxisCount;
          double childAspectRatio;

          if (screenWidth < 600) {
            // Mobile
            crossAxisCount = 3;
            childAspectRatio = 0.45;
          } else if (screenWidth < 900) {
            // Tablet
            crossAxisCount = 4;
            childAspectRatio = 0.50;
          } else {
            // Desktop
            crossAxisCount = 6;
            childAspectRatio = 0.55;
          }

          return Stack(
            children: [
              // Background Gradient (Flat / Clean)
              Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [AppColors.airBlue, AppColors.mistWhite],
                    stops: [0.0, 0.3],
                  ),
                ),
              ),

              // Main Content
              SafeArea(
                child: Column(
                  children: [
                    // Search & Actions Bar
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 10, 20, 20),
                      child: Row(
                        children: [
                          // Search Box
                          Expanded(
                            child: SizedBox(
                              height: 48,
                              child: GlassPanel(
                                borderRadius:
                                    BorderRadius.circular(AppTokens.radiusMd),
                                surfaceColor: Colors.white,
                                opacity: 0.60,
                                border: Border.all(
                                  color:
                                      AppColors.deepSpace.withOpacityCompat(0.06),
                                  width: AppTokens.stroke,
                                ),
                                child: TextField(
                                  controller: _searchController,
                                  onChanged: _onSearchChanged,
                                  style: const TextStyle(
                                      color: AppColors.deepSpace),
                                  decoration: InputDecoration(
                                    hintText: '搜索书名或作者',
                                    hintStyle: const TextStyle(
                                        color: AppColors.softGrey),
                                    prefixIcon: const Icon(Icons.search,
                                        color: AppColors.softGrey),
                                    border: InputBorder.none,
                                    contentPadding: const EdgeInsets.symmetric(
                                        horizontal: 16, vertical: 12),
                                    suffixIcon: _searchQuery.isNotEmpty
                                        ? IconButton(
                                            icon: const Icon(Icons.close,
                                                size: 20,
                                                color: AppColors.softGrey),
                                            onPressed: () {
                                              _searchController.clear();
                                              _onSearchChanged('');
                                            },
                                          )
                                        : null,
                                  ),
                                ),
                              ),
                            ),
                          ),

                          const SizedBox(width: 8),

                          _buildActionButton(
                            context: context,
                            icon: Icons.add,
                            onTap: () => _handleImport(context),
                            tooltip: '导入书籍',
                          ),

                          const SizedBox(width: 8),

                          _buildActionButton(
                            context: context,
                            icon: booksProvider.isSelectionMode
                                ? Icons.close
                                : Icons.checklist_rtl_rounded,
                            onTap: () => booksProvider.toggleSelectionMode(),
                            tooltip:
                                booksProvider.isSelectionMode ? '取消选择' : '管理书籍',
                            isActive: booksProvider.isSelectionMode,
                          ),
                        ],
                      ),
                    ),

                    // Books Grid
                    Expanded(
                      child: displayBooks.isEmpty
                          ? Center(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(Icons.library_books_outlined,
                                      size: 80,
                                      color:
                                          AppColors.softGrey
                                              .withOpacityCompat(0.3)),
                                  const SizedBox(height: 24),
                                  Text(
                                    _searchQuery.isNotEmpty
                                        ? '未找到相关书籍'
                                        : '书架空空如也，快去导入书籍吧！',
                                    textAlign: TextAlign.center,
                                    style: const TextStyle(
                                      color: AppColors.softGrey,
                                      fontSize: 16,
                                    ),
                                  ),
                                  if (_searchQuery.isEmpty) ...[
                                    const SizedBox(height: 32),
                                    ElevatedButton.icon(
                                      onPressed: () => _handleImport(context),
                                      icon: const Icon(Icons.add),
                                      label: const Text('导入书籍'),
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: AppColors.techBlue,
                                        foregroundColor: Colors.white,
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 32, vertical: 16),
                                        shape: RoundedRectangleBorder(
                                            borderRadius:
                                                BorderRadius.circular(30)),
                                        elevation: 0, // Flat style
                                      ),
                                    ),
                                  ]
                                ],
                              ),
                            )
                          : GridView.builder(
                              padding:
                                  const EdgeInsets.fromLTRB(20, 0, 20, 100),
                              gridDelegate:
                                  SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: crossAxisCount,
                                childAspectRatio: childAspectRatio,
                                crossAxisSpacing: 32,
                                mainAxisSpacing: 40,
                              ),
                              itemCount: displayBooks.length,
                              itemBuilder: (context, index) {
                                final book = displayBooks[index];
                                return BookCard(
                                  key: ValueKey(book.id),
                                  book: book,
                                  itemIndex: index,
                                  totalColumns: crossAxisCount,
                                  childAspectRatio: childAspectRatio,
                                  isSelectionMode:
                                      booksProvider.isSelectionMode,
                                  isSelected: booksProvider.selectedBookIds
                                      .contains(book.id),
                                  onSelectionToggle: () => booksProvider
                                      .toggleBookSelection(book.id),
                                  onTap: () {
                                    if (booksProvider.isSelectionMode) {
                                      booksProvider
                                          .toggleBookSelection(book.id);
                                    } else {
                                      Navigator.push(
                                        context,
                                        PageRouteBuilder(
                                          pageBuilder: (context, animation,
                                                  secondaryAnimation) =>
                                              ReaderPage(bookId: book.id),
                                          transitionsBuilder: (context,
                                              animation,
                                              secondaryAnimation,
                                              child) {
                                            const begin = Offset(0.0, 1.0);
                                            const end = Offset.zero;
                                            const curve = Curves.easeInOutCubic;

                                            var tween = Tween(
                                                    begin: begin, end: end)
                                                .chain(
                                                    CurveTween(curve: curve));

                                            return FadeTransition(
                                              opacity: animation,
                                              child: SlideTransition(
                                                position:
                                                    animation.drive(tween),
                                                child: child,
                                              ),
                                            );
                                          },
                                          transitionDuration:
                                              const Duration(milliseconds: 500),
                                        ),
                                      );
                                    }
                                  },
                                );
                              },
                            ),
                    ),
                  ],
                ),
              ),

              // Bottom Delete Bar (Selection Mode)
              if (booksProvider.isSelectionMode)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: GlassPanel(
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(AppTokens.radiusLg),
                    ),
                    surfaceColor: Colors.white,
                    opacity: 0.92,
                    boxShadow: AppTokens.shadowSoft,
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(
                        48,
                        16,
                        48,
                        16 + MediaQuery.of(context).padding.bottom,
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          // Pin Button
                          Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                onPressed: booksProvider.selectedBookIds.isEmpty
                                    ? null
                                    : () => booksProvider.pinSelectedBooks(),
                                icon: const Icon(
                                    Icons.vertical_align_top_rounded,
                                    size: 28),
                                color: AppColors.deepSpace,
                                disabledColor: Colors.grey[300],
                              ),
                              Text(
                                '置顶',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: booksProvider.selectedBookIds.isEmpty
                                      ? Colors.grey[300]
                                      : AppColors.deepSpace,
                                ),
                              )
                            ],
                          ),

                          // Select All Button (Moved from AppBar)
                          Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                onPressed: () => booksProvider.selectAll(),
                                icon: const Icon(Icons.select_all_rounded,
                                    size: 28),
                                color: AppColors.techBlue,
                              ),
                              const Text(
                                '全选',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: AppColors.techBlue,
                                ),
                              )
                            ],
                          ),

                          // Delete Button
                          Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                onPressed: booksProvider.selectedBookIds.isEmpty
                                    ? null
                                    : () => booksProvider.deleteSelectedBooks(),
                                icon: const Icon(Icons.delete_outline_rounded,
                                    size: 28),
                                color: Colors.redAccent,
                                disabledColor: Colors.grey[300],
                              ),
                              Text(
                                '删除',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: booksProvider.selectedBookIds.isEmpty
                                      ? Colors.grey[300]
                                      : Colors.redAccent,
                                ),
                              )
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ), // <- 补这一行：关闭 Positioned
            ],
          );
        },
      ),
    );
  }
}

Widget _buildActionButton({
  required BuildContext context,
  required IconData icon,
  required VoidCallback onTap,
  required String tooltip,
  bool isActive = false,
}) {
  final onSurface = Theme.of(context).colorScheme.onSurface;

  return Material(
    color: Colors.transparent,
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppTokens.radiusMd),
      child: SizedBox(
        width: 48,
        height: 48,
        child: GlassPanel(
          borderRadius: BorderRadius.circular(AppTokens.radiusMd),
          surfaceColor: Colors.white,
          opacity: isActive ? 0.72 : 0.60,
          border: Border.all(
            color: (isActive ? AppColors.techBlue : onSurface)
                .withOpacityCompat(isActive ? 0.28 : 0.08),
            width: AppTokens.stroke,
          ),
          child: Center(
            child: Icon(
              icon,
              color: isActive ? AppColors.techBlue : AppColors.deepSpace,
              size: 24,
            ),
          ),
        ),
      ),
    ),
  );
}
