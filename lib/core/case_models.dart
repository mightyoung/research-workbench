/// V6.6 research-skill commit used for a new case.
const defaultMethodCommit = 'b09f09499dd2ac64317dd1291532e5aac562fae8';

/// V6.4 research-skill commit that historical cases may keep.
const v64MethodCommit = '03f768c8526fb9d9c1d31ae808b36c5e17e77c25';

/// One pinned source. All four fields are stored explicitly.
class SourceRef {
  const SourceRef({
    required this.snapshotId,
    required this.kind,
    required this.sourceId,
    required this.rev,
  });

  final String snapshotId, kind, sourceId;
  final int rev;

  Map<String, dynamic> toJson() => {
    'snapshotId': snapshotId,
    'kind': kind,
    'sourceId': sourceId,
    'rev': rev,
  };

  factory SourceRef.fromJson(Map<String, dynamic> json) => SourceRef(
    snapshotId: json['snapshotId'] as String? ?? '',
    kind: json['kind'] as String? ?? '',
    sourceId: json['sourceId'] as String? ?? '',
    rev: (json['rev'] as num?)?.toInt() ?? 0,
  );
}

class ResearchCase {
  const ResearchCase({
    required this.id,
    required this.projectId,
    required this.question,
    required this.methodCommit,
    this.workflowId,
    this.candidates = const [],
    required this.processState,
    required this.scientificJudgement,
  });

  final String id, projectId, question, methodCommit;
  final String? workflowId;
  final List<SourceRef> candidates;
  final String processState, scientificJudgement;
}

/// One append-only plan revision. An existing version is never overwritten.
class PlanVersion {
  const PlanVersion({
    required this.planId,
    required this.version,
    required this.caseId,
    this.parentVersion,
    required this.reason,
    required this.branch,
  });

  final String planId, caseId, reason, branch;
  final int version;
  final int? parentVersion;
}

class ExecutionAttempt {
  const ExecutionAttempt({
    required this.attemptId,
    required this.caseId,
    required this.planId,
    required this.planVersion,
    this.taskId,
    this.taskRevision,
    required this.executorId,
    required this.processStatus,
  });

  final String attemptId, caseId, planId, executorId, processStatus;
  final int planVersion;
  final String? taskId;
  final int? taskRevision;
}

class CaseEvent {
  const CaseEvent({
    required this.id,
    required this.caseId,
    required this.type,
    required this.sourceRefs,
    required this.payload,
    required this.position,
  });

  final String id, caseId, type;
  final List<SourceRef> sourceRefs;
  final Map<String, dynamic> payload;
  final int position;
}

class CaseTimeline {
  const CaseTimeline({
    required this.researchCase,
    required this.plans,
    required this.attempts,
    required this.events,
  });

  final ResearchCase researchCase;
  final List<PlanVersion> plans;
  final List<ExecutionAttempt> attempts;
  final List<CaseEvent> events;
}
