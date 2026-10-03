class ResearchProject {
  const ResearchProject({
    required this.id,
    required this.title,
    this.question = '',
    this.nextStep = '',
  });
  final String id, title, question, nextStep;
}

class ResearchEntry {
  const ResearchEntry({
    required this.id,
    required this.projectId,
    required this.kind,
    required this.title,
    required this.data,
  });
  final String id, projectId, kind, title;
  final Map<String, dynamic> data;
}

class ResearchDocument {
  const ResearchDocument({
    required this.id,
    required this.projectId,
    required this.relativePath,
    required this.absolutePath,
  });
  final String id, projectId, relativePath, absolutePath;
  String get title => relativePath.split('/').last;
  bool get isPdf => relativePath.toLowerCase().endsWith('.pdf');
}

/// The newest version of each path, given documents ordered oldest-first per
/// path (older versions are kept only for the notes written on them).
List<ResearchDocument> currentVersions(List<ResearchDocument> docs) =>
    {for (final d in docs) d.relativePath: d}.values.toList();

class ResearchTask {
  const ResearchTask({
    required this.id,
    required this.projectId,
    required this.title,
    required this.goal,
    required this.revision,
    required this.spec,
  });
  final String id, projectId, title, goal;
  final int revision;
  final Map<String, dynamic> spec;
}

class ResearchRun {
  const ResearchRun({
    required this.id,
    required this.taskId,
    required this.status,
    required this.taskRevision,
    required this.accepted,
    required this.data,
  });
  final String id, taskId, status;
  final int taskRevision;
  final bool accepted;
  final Map<String, dynamic> data;
}

class ReadingNote {
  const ReadingNote({
    required this.id,
    required this.documentId,
    required this.locator,
    required this.text,
    this.pageNumber,
    this.quote = '',
  });
  final String id, documentId, locator, text;
  final int? pageNumber;
  final String quote;
}

/// Keeps the highest `rev` of each source record `id`; records without an id
/// stand alone. Input order is preserved.
List<ResearchEntry> latestRevisions(List<ResearchEntry> entries) {
  int rev(ResearchEntry e) => e.data['rev'] is int ? e.data['rev'] as int : 0;
  String? key(ResearchEntry e) =>
      e.data['id'] == null ? null : '${e.kind}\u0000${e.data['id']}';
  final best = <String, ResearchEntry>{};
  for (final e in entries) {
    final k = key(e);
    if (k != null && (best[k] == null || rev(e) > rev(best[k]!))) best[k] = e;
  }
  return entries.where((e) => key(e) == null || best[key(e)] == e).toList();
}
