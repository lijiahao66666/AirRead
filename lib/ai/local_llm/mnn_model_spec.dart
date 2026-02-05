class MnnModelSpec {
  final String id;
  final String displayName;
  final String sizeLabel;
  final int estimatedTotalSizeBytes;
  final String baseUrl;
  final List<String> filesToDownload;
  final List<String> criticalFiles;
  final Map<String, int> minExpectedBytesByFile;
  final String progressFileName;

  const MnnModelSpec({
    required this.id,
    required this.displayName,
    required this.sizeLabel,
    required this.estimatedTotalSizeBytes,
    required this.baseUrl,
    required this.filesToDownload,
    required this.criticalFiles,
    required this.minExpectedBytesByFile,
    this.progressFileName = 'llm.mnn.weight',
  });

  String get modelDirRelative => 'models/$id';
}

