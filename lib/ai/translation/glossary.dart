import 'dart:collection';

class GlossaryTerm {
  final String source;
  final String target;

  const GlossaryTerm({required this.source, required this.target});

  Map<String, dynamic> toJson() => {
        'source': source,
        'target': target,
      };

  static GlossaryTerm fromJson(Map<String, dynamic> json) {
    return GlossaryTerm(
      source: (json['source'] ?? '').toString(),
      target: (json['target'] ?? '').toString(),
    );
  }
}

class GlossaryApplyResult {
  final String textWithPlaceholders;
  final Map<String, String> placeholderToTarget;

  const GlossaryApplyResult({
    required this.textWithPlaceholders,
    required this.placeholderToTarget,
  });
}

class GlossaryManager {
  final List<GlossaryTerm> _terms = [];
  int _version = 1;

  int get version => _version;
  UnmodifiableListView<GlossaryTerm> get terms => UnmodifiableListView(_terms);

  void replaceAll(List<GlossaryTerm> terms) {
    _terms
      ..clear()
      ..addAll(terms);
    _bumpVersion();
  }

  void addOrUpdate(GlossaryTerm term) {
    final idx = _terms.indexWhere((t) => t.source == term.source);
    if (idx >= 0) {
      _terms[idx] = term;
    } else {
      _terms.add(term);
    }
    _bumpVersion();
  }

  void removeBySource(String source) {
    _terms.removeWhere((t) => t.source == source);
    _bumpVersion();
  }

  void _bumpVersion() {
    _version++;
  }

  /// Replace glossary source terms with stable placeholders so engines keep them untouched.
  GlossaryApplyResult applyToSourceText(String input) {
    if (_terms.isEmpty) {
      return GlossaryApplyResult(textWithPlaceholders: input, placeholderToTarget: const {});
    }

    final sorted = [..._terms]
      ..sort((a, b) => b.source.length.compareTo(a.source.length));

    var out = input;
    final Map<String, String> placeholderToTarget = {};

    for (int i = 0; i < sorted.length; i++) {
      final term = sorted[i];
      if (term.source.trim().isEmpty || term.target.trim().isEmpty) continue;

      final placeholder = '{{AR_TERM_$i}}';
      if (out.contains(term.source)) {
        out = out.replaceAll(term.source, placeholder);
        placeholderToTarget[placeholder] = term.target;
      }
    }

    return GlossaryApplyResult(
      textWithPlaceholders: out,
      placeholderToTarget: placeholderToTarget,
    );
  }

  String applyToTranslatedText(String translated, Map<String, String> placeholderToTarget) {
    var out = translated;
    placeholderToTarget.forEach((placeholder, target) {
      out = out.replaceAll(placeholder, target);
    });
    return out;
  }
}
