class OnlineBook {
  final String id;
  final String title;
  final List<String> authors;
  final String? coverUrl;
  final Map<String, String> downloadUrls; // format -> url
  final String? description;
  final List<String> subjects;
  final int downloadCount;

  OnlineBook({
    required this.id,
    required this.title,
    required this.authors,
    this.coverUrl,
    required this.downloadUrls,
    this.description,
    this.subjects = const [],
    this.downloadCount = 0,
  });

  factory OnlineBook.fromGutenberg(Map<String, dynamic> json) {
    final formats = json['formats'] as Map<String, dynamic>? ?? {};
    final Map<String, String> dUrls = {};
    
    // Gutendex format mapping
    formats.forEach((key, value) {
      if (key.toString().contains('application/epub+zip')) {
        dUrls['epub'] = value.toString();
      } else if (key.toString().contains('text/plain')) {
        dUrls['txt'] = value.toString();
      }
    });

    final authorsList = (json['authors'] as List?)?.map((a) {
      return a['name'].toString();
    }).toList() ?? ['Unknown Author'];

    return OnlineBook(
      id: json['id']?.toString() ?? '',
      title: json['title'] ?? 'Unknown Title',
      authors: authorsList,
      coverUrl: formats['image/jpeg']?.toString(),
      downloadUrls: dUrls,
      subjects: (json['subjects'] as List?)?.map((s) => s.toString()).toList() ?? [],
      downloadCount: json['download_count'] ?? 0,
    );
  }
}
