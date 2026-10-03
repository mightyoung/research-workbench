class ResearchProject {
  const ResearchProject({
    required this.id,
    required this.title,
    this.question = '',
    this.nextStep = '',
    this.layout = 'generic',
    this.skillRoot = '',
  });
  final String id, title, question, nextStep;

  /// generic, research-skill-v1 or research-skill-v2.
  final String layout;

  /// Snapshot-relative prefix of the research-skill project root.
  final String skillRoot;
  bool get isSkill => layout.startsWith('research-skill');
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
    this.sha256,
  });
  final String id, projectId, relativePath, absolutePath;
  final String? sha256;
  String get title => relativePath.split('/').last;
  bool get isPdf => relativePath.toLowerCase().endsWith('.pdf');
}

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
    this.evidenceKind,
    this.doesNotSupport = '',
    this.needsReview = false,
  });
  final String id, documentId, locator, text;
  final int? pageNumber;
  final String quote;
  final String? evidenceKind;
  final String doesNotSupport;

  /// Set when a re-import found the document's bytes changed.
  final bool needsReview;
}

/// Link between an imported document and a research-skill paper revision.
class PaperBinding {
  const PaperBinding({
    required this.documentId,
    required this.paperId,
    required this.paperRev,
    required this.method,
    required this.hashOk,
    this.ambiguous = false,
  });
  final String documentId, paperId, method;
  final int paperRev;
  final bool hashOk, ambiguous;
}
