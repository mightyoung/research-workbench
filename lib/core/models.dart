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
