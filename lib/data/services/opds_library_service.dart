import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

import '../models/online_book.dart';

class OpdsLibraryService {
  final http.Client _client;
  String? _cachedCatalogUrl;
  String? _cachedSearchTemplate;

  OpdsLibraryService({http.Client? client}) : _client = client ?? http.Client();

  Future<List<OnlineBook>> search({
    required String catalogOrTemplateUrl,
    required String query,
  }) async {
    final q = query.trim();
    if (q.isEmpty) return [];

    final base = catalogOrTemplateUrl.trim();
    if (base.isEmpty) {
      throw Exception('请先配置 OPDS 地址');
    }

    final searchUrl = await _buildSearchUrl(catalogOrTemplateUrl: base, query: q);
    final response = await _client
        .get(Uri.parse(searchUrl))
        .timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) {
      throw Exception('OPDS 搜索失败: ${response.statusCode}');
    }
    final xmlText = utf8.decode(response.bodyBytes);
    return parseFeed(xmlText, Uri.parse(searchUrl));
  }

  static List<OnlineBook> parseFeed(String xmlText, Uri baseUri) {
    final doc = XmlDocument.parse(xmlText);
    final entries = doc.findAllElements('entry');

    final results = <OnlineBook>[];
    for (final entry in entries) {
      final title = entry.getElement('title')?.innerText.trim();
      if (title == null || title.isEmpty) continue;

      final idText = entry.getElement('id')?.innerText.trim();
      final id = (idText == null || idText.isEmpty) ? title : idText;

      final authors = entry
          .findAllElements('author')
          .map((a) => a.getElement('name')?.innerText.trim())
          .whereType<String>()
          .where((s) => s.isNotEmpty)
          .toList();

      final summary = entry.getElement('summary')?.innerText.trim();
      final content = entry.getElement('content')?.innerText.trim();
      final description = (summary != null && summary.isNotEmpty)
          ? summary
          : (content != null && content.isNotEmpty ? content : null);

      final links = entry.findAllElements('link');
      final coverUrl = _pickCoverUrlStatic(links: links, baseUri: baseUri);
      final downloadUrls =
          _pickAcquisitionUrlsStatic(links: links, baseUri: baseUri);
      if (downloadUrls.isEmpty) continue;

      results.add(
        OnlineBook(
          id: id,
          title: title,
          authors: authors.isEmpty ? const ['Unknown Author'] : authors,
          coverUrl: coverUrl,
          downloadUrls: downloadUrls,
          description: description,
        ),
      );
    }

    return results;
  }

  Future<String> _buildSearchUrl({
    required String catalogOrTemplateUrl,
    required String query,
  }) async {
    if (catalogOrTemplateUrl.contains('{searchTerms}')) {
      return catalogOrTemplateUrl.replaceAll(
        '{searchTerms}',
        Uri.encodeQueryComponent(query),
      );
    }

    final template = await _getSearchTemplate(catalogOrTemplateUrl);
    return template.replaceAll(
      '{searchTerms}',
      Uri.encodeQueryComponent(query),
    );
  }

  Future<String> _getSearchTemplate(String catalogUrl) async {
    if (_cachedCatalogUrl == catalogUrl && _cachedSearchTemplate != null) {
      return _cachedSearchTemplate!;
    }

    final response =
        await _client.get(Uri.parse(catalogUrl)).timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) {
      throw Exception('OPDS 目录请求失败: ${response.statusCode}');
    }

    final doc = XmlDocument.parse(utf8.decode(response.bodyBytes));
    final direct = _tryParseOpenSearchTemplate(doc);
    if (direct != null) {
      _cachedCatalogUrl = catalogUrl;
      _cachedSearchTemplate = direct;
      return direct;
    }

    String? href;
    for (final e in doc.findAllElements('link')) {
      if ((e.getAttribute('rel') ?? '').trim() == 'search') {
        href = e.getAttribute('href');
        break;
      }
    }
    if (href == null || href.trim().isEmpty) {
      throw Exception('该 OPDS 目录未提供 search 链接，请使用包含 {searchTerms} 的搜索模板 URL');
    }

    final searchDescUrl = Uri.parse(catalogUrl).resolve(href.trim()).toString();
    final descResp = await _client
        .get(Uri.parse(searchDescUrl))
        .timeout(const Duration(seconds: 20));
    if (descResp.statusCode != 200) {
      throw Exception('OpenSearch 描述请求失败: ${descResp.statusCode}');
    }

    final descDoc = XmlDocument.parse(utf8.decode(descResp.bodyBytes));
    final template = _tryParseOpenSearchTemplate(descDoc);
    if (template == null) {
      throw Exception('无法解析 OpenSearch 模板，请使用包含 {searchTerms} 的搜索模板 URL');
    }

    _cachedCatalogUrl = catalogUrl;
    _cachedSearchTemplate = template;
    return template;
  }

  String? _tryParseOpenSearchTemplate(XmlDocument doc) {
    for (final url in doc.findAllElements('Url')) {
      final template = url.getAttribute('template')?.trim();
      if (template != null && template.contains('{searchTerms}')) {
        return template;
      }
    }
    return null;
  }

  static String? _pickCoverUrlStatic({
    required Iterable<XmlElement> links,
    required Uri baseUri,
  }) {
    String? candidate;
    String? fallback;

    for (final link in links) {
      final rel = (link.getAttribute('rel') ?? '').trim();
      final href = (link.getAttribute('href') ?? '').trim();
      if (href.isEmpty) continue;

      if (rel == 'http://opds-spec.org/image/thumbnail' ||
          rel == 'http://opds-spec.org/image') {
        candidate = baseUri.resolve(href).toString();
        if (rel == 'http://opds-spec.org/image') return candidate;
      }

      final type = (link.getAttribute('type') ?? '').toLowerCase();
      if (fallback == null && type.startsWith('image/')) {
        fallback = baseUri.resolve(href).toString();
      }
    }

    return candidate ?? fallback;
  }

  static Map<String, String> _pickAcquisitionUrlsStatic({
    required Iterable<XmlElement> links,
    required Uri baseUri,
  }) {
    final urls = <String, String>{};
    for (final link in links) {
      final rel = (link.getAttribute('rel') ?? '').trim();
      if (!rel.startsWith('http://opds-spec.org/acquisition')) continue;

      final href = (link.getAttribute('href') ?? '').trim();
      if (href.isEmpty) continue;

      final type = (link.getAttribute('type') ?? '').trim();
      final formatKey = _formatKey(type: type, href: href);
      if (formatKey == null) continue;

      urls.putIfAbsent(formatKey, () => baseUri.resolve(href).toString());
    }
    return urls;
  }

  static String? _formatKey({required String type, required String href}) {
    final t = type.toLowerCase();
    if (t.contains('application/epub')) return 'epub';
    if (t.contains('text/plain')) return 'txt';
    final path = Uri.tryParse(href)?.path.toLowerCase() ?? href.toLowerCase();
    if (path.endsWith('.epub')) return 'epub';
    if (path.endsWith('.txt')) return 'txt';
    return null;
  }

  void dispose() {
    _client.close();
  }
}
