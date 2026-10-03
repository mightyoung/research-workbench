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
    this.evidenceKind,
    this.doesNotSupport = '',
    this.entryId,
  });
  final String id, documentId, locator, text;
  final int? pageNumber;
  final String quote;
  final String? evidenceKind;
  final String doesNotSupport;

  /// Local ID of the research record this note is about, if any.
  final String? entryId;
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

/// Evidence support levels a writer assigns to an outline section.
const sectionSupport = {
  'unassessed': '未评估',
  'supported': '证据充分',
  'partial': '部分支持',
  'weak': '证据不足',
  'contested': '存在反证',
};

class OutlineSection {
  const OutlineSection({
    required this.id,
    required this.projectId,
    required this.heading,
    required this.level,
    required this.position,
    required this.argument,
    required this.support,
  });
  final String id, projectId, heading, argument, support;

  /// Nesting depth 1–3, rendered as Markdown `##`–`####`.
  final int level, position;
}
