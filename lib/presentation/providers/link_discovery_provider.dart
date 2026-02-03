import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../ai/hunyuan/hunyuan_text_client.dart';
import '../../ai/tencentcloud/embedded_public_hunyuan_credentials.dart';

enum LinkRiskLevel {
  low,
  medium,
  high,
}

enum LinkGroup {
  searchEngine,
  metadata,
  buy,
  library,
  publicDomain,
  userProvided,
}

class LinkCandidate {
  final String title;
  final String url;
  final LinkGroup group;
  final LinkRiskLevel risk;
  final String? riskReason;

  LinkCandidate({
    required this.title,
    required this.url,
    required this.group,
    this.risk = LinkRiskLevel.medium,
    this.riskReason,
  });

  Uri? get uri => Uri.tryParse(url);
  String get host => uri?.host ?? '';

  LinkCandidate copyWith({
    String? title,
    String? url,
    LinkGroup? group,
    LinkRiskLevel? risk,
    String? riskReason,
  }) {
    return LinkCandidate(
      title: title ?? this.title,
      url: url ?? this.url,
      group: group ?? this.group,
      risk: risk ?? this.risk,
      riskReason: riskReason ?? this.riskReason,
    );
  }
}

class LinkDiscoveryProvider extends ChangeNotifier {
  String _query = '';
  String _rawUrlsInput = '';

  List<LinkCandidate> _candidates = [];
  bool _isLabeling = false;
  String? _labelError;

  String get query => _query;
  String get rawUrlsInput => _rawUrlsInput;
  List<LinkCandidate> get candidates => _candidates;
  bool get isLabeling => _isLabeling;
  String? get labelError => _labelError;

  void setQuery(String v) {
    _query = v;
    notifyListeners();
  }

  void setRawUrlsInput(String v) {
    _rawUrlsInput = v;
    notifyListeners();
  }

  void buildCandidates() {
    final q = _query.trim();
    final list = <LinkCandidate>[];

    if (q.isNotEmpty) {
      list.addAll(_templatesForQuery(q));
    }
    list.addAll(_parseUserUrls(_rawUrlsInput));

    _candidates = _dedupe(list);
    _labelError = null;
    notifyListeners();
  }

  Future<void> labelWithAi() async {
    _labelError = null;
    final current = _candidates;
    if (current.isEmpty) return;

    _isLabeling = true;
    notifyListeners();

    try {
      final credentials = getEmbeddedPublicHunyuanCredentials();
      if (!credentials.isUsable) {
        _labelError = 'AI 未配置，已使用基础规则标注';
        _candidates = current.map(_heuristicLabel).toList();
        return;
      }

      final client = HunyuanTextClient(credentials: credentials);
      final input = current
          .map((c) => {
                'title': c.title,
                'url': c.url,
                'group': c.group.name,
              })
          .toList();

      final prompt = _buildPrompt(input);
      final text = await _chatOnceViaStream(client, prompt);
      final decoded = jsonDecode(_extractJson(text));
      if (decoded is! List) {
        throw Exception('AI 返回格式不正确');
      }

      final byUrl = <String, Map<String, dynamic>>{};
      for (final item in decoded) {
        if (item is! Map) continue;
        final url = item['url']?.toString();
        if (url == null || url.isEmpty) continue;
        byUrl[url] = item.cast<String, dynamic>();
      }

      _candidates = current.map((c) {
        final item = byUrl[c.url];
        if (item == null) return _heuristicLabel(c);
        final risk = _parseRisk(item['risk']?.toString());
        final reason = item['reason']?.toString();
        return _heuristicLabel(c).copyWith(risk: risk, riskReason: reason);
      }).toList();
    } catch (e) {
      _labelError = 'AI 标注失败：$e（已使用基础规则标注）';
      _candidates = current.map(_heuristicLabel).toList();
    } finally {
      _isLabeling = false;
      notifyListeners();
    }
  }

  Future<String> _chatOnceViaStream(HunyuanTextClient client, String prompt) async {
    final buffer = StringBuffer();
    await for (final chunk in client.chatStream(
      userText: prompt,
      model: 'hunyuan-a13b',
    )) {
      if (chunk.content.isNotEmpty) {
        buffer.write(chunk.content);
      }
      if (chunk.isComplete) break;
    }
    return buffer.toString();
  }

  List<LinkCandidate> _templatesForQuery(String q) {
    final enc = Uri.encodeComponent(q);
    return [
      LinkCandidate(
        title: '百度搜索：$q',
        url: 'https://www.baidu.com/s?wd=$enc',
        group: LinkGroup.searchEngine,
        risk: LinkRiskLevel.low,
      ),
      LinkCandidate(
        title: '必应搜索：$q',
        url: 'https://cn.bing.com/search?q=$enc',
        group: LinkGroup.searchEngine,
        risk: LinkRiskLevel.low,
      ),
      LinkCandidate(
        title: '豆瓣图书搜索：$q',
        url: 'https://book.douban.com/subject_search?search_text=$enc',
        group: LinkGroup.metadata,
        risk: LinkRiskLevel.low,
      ),
      LinkCandidate(
        title: '京东搜索：$q',
        url: 'https://search.jd.com/Search?keyword=$enc',
        group: LinkGroup.buy,
        risk: LinkRiskLevel.low,
      ),
      LinkCandidate(
        title: '当当搜索：$q',
        url: 'https://search.dangdang.com/?key=$enc',
        group: LinkGroup.buy,
        risk: LinkRiskLevel.low,
      ),
      LinkCandidate(
        title: 'Gutendex（公版）搜索：$q',
        url: 'https://gutendex.com/books/?search=$enc',
        group: LinkGroup.publicDomain,
        risk: LinkRiskLevel.low,
      ),
      LinkCandidate(
        title: 'Open Library 搜索：$q',
        url: 'https://openlibrary.org/search?q=$enc',
        group: LinkGroup.metadata,
        risk: LinkRiskLevel.low,
      ),
    ];
  }

  List<LinkCandidate> _parseUserUrls(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return [];

    final re = RegExp(r'(https?://[^\s<>"\u3000]+)', caseSensitive: false);
    final matches = re.allMatches(text).map((m) => m.group(0)).whereType<String>();

    final list = <LinkCandidate>[];
    for (final u in matches) {
      final uri = Uri.tryParse(u);
      if (uri == null || !(uri.scheme == 'http' || uri.scheme == 'https')) continue;
      list.add(
        LinkCandidate(
          title: uri.host.isEmpty ? '用户链接' : uri.host,
          url: uri.toString(),
          group: LinkGroup.userProvided,
          risk: LinkRiskLevel.medium,
        ),
      );
    }
    return list;
  }

  List<LinkCandidate> _dedupe(List<LinkCandidate> list) {
    final seen = <String>{};
    final out = <LinkCandidate>[];
    for (final c in list) {
      if (seen.add(c.url)) out.add(c);
    }
    return out;
  }

  LinkCandidate _heuristicLabel(LinkCandidate c) {
    final host = c.host.toLowerCase();
    if (host.isEmpty) {
      return c.copyWith(risk: LinkRiskLevel.medium, riskReason: c.riskReason);
    }

    final highSignals = [
      'zlibrary',
      'z-lib',
      'libgen',
      'sci-hub',
      'annas-archive',
      'pdfdrive',
      'ebook',
      'download',
    ];
    if (highSignals.any(host.contains)) {
      return c.copyWith(
        risk: LinkRiskLevel.high,
        riskReason: c.riskReason ?? '来源不明/高风险站点特征',
      );
    }

    final lowHosts = [
      'baidu.com',
      'bing.com',
      'douban.com',
      'jd.com',
      'dangdang.com',
      'openlibrary.org',
      'gutendex.com',
    ];
    if (lowHosts.any((h) => host == h || host.endsWith('.$h'))) {
      return c.copyWith(risk: LinkRiskLevel.low, riskReason: c.riskReason);
    }

    return c.copyWith(risk: LinkRiskLevel.medium, riskReason: c.riskReason);
  }

  LinkRiskLevel _parseRisk(String? s) {
    final v = (s ?? '').trim().toLowerCase();
    if (v == 'low') return LinkRiskLevel.low;
    if (v == 'high') return LinkRiskLevel.high;
    return LinkRiskLevel.medium;
  }

  String _buildPrompt(List<Map<String, dynamic>> items) {
    return [
      '你是一个“链接风险与类型标注器”。',
      '请仅根据 URL/域名与标题，给每个链接做 risk 标注与简短原因。',
      'risk 只能是 low/medium/high。',
      '不要输出任何解释文字，只输出 JSON 数组，每项格式：{"url":"...","risk":"low|medium|high","reason":"..."}。',
      '输入如下：',
      jsonEncode(items),
    ].join('\n');
  }

  String _extractJson(String text) {
    final s = text.trim();
    final start = s.indexOf('[');
    final end = s.lastIndexOf(']');
    if (start != -1 && end != -1 && end > start) {
      return s.substring(start, end + 1);
    }
    return s;
  }
}
