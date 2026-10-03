import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';
import 'package:uuid/uuid.dart';

import 'case_models.dart';
import 'store.dart';

/// Append-only research cases on the connection [WorkbenchStore] already owns.
extension CaseStore on WorkbenchStore {
  void saveCase(ResearchCase item) {
    db.execute(
      '''
INSERT INTO research_cases(
  id, project_id, question, method_commit, workflow_id, candidates,
  process_state, scientific_judgement)
VALUES(?,?,?,?,?,?,?,?)
ON CONFLICT(id) DO UPDATE SET
  project_id=excluded.project_id,
  question=excluded.question,
  method_commit=excluded.method_commit,
  workflow_id=excluded.workflow_id,
  candidates=excluded.candidates,
  process_state=excluded.process_state,
  scientific_judgement=excluded.scientific_judgement
''',
      [
        item.id,
        item.projectId,
        item.question,
        item.methodCommit,
        item.workflowId,
        jsonEncode([for (final ref in item.candidates) ref.toJson()]),
        item.processState,
        item.scientificJudgement,
      ],
    );
  }

  ResearchCase? caseById(String id) {
    final rows = db.select('SELECT * FROM research_cases WHERE id=?', [id]);
    return rows.isEmpty ? null : _caseFrom(rows.single);
  }

  List<ResearchCase> casesFor(String projectId) => db
      .select(
        'SELECT * FROM research_cases WHERE project_id=? ORDER BY rowid',
        [projectId],
      )
      .map(_caseFrom)
      .toList();

  void appendPlan(PlanVersion plan) {
    _requireCase(plan.caseId);
    db.execute(
      '''
INSERT INTO plan_versions(
  plan_id, version, case_id, parent_version, reason, branch)
VALUES(?,?,?,?,?,?)
''',
      [
        plan.planId,
        plan.version,
        plan.caseId,
        plan.parentVersion,
        plan.reason,
        plan.branch,
      ],
    );
  }

  CaseEvent appendEvent(
    String caseId,
    String type,
    List<SourceRef> sourceRefs,
    Map<String, dynamic> payload,
  ) {
    _requireCase(caseId);
    final position =
        (db.select(
                  'SELECT MAX(position) AS m FROM case_events WHERE case_id=?',
                  [caseId],
                ).first['m']
                as int? ??
            0) +
        1;
    final id = const Uuid().v4();
    db.execute(
      '''
INSERT INTO case_events(id, case_id, type, source_refs, payload, position)
VALUES(?,?,?,?,?,?)
''',
      [
        id,
        caseId,
        type,
        jsonEncode([for (final ref in sourceRefs) ref.toJson()]),
        jsonEncode(payload),
        position,
      ],
    );
    return CaseEvent(
      id: id,
      caseId: caseId,
      type: type,
      sourceRefs: sourceRefs,
      payload: payload,
      position: position,
    );
  }

  void createAttempt(ExecutionAttempt attempt) {
    _requireCase(attempt.caseId);
    db.execute(
      '''
INSERT INTO execution_attempts(
  id, case_id, plan_id, plan_version, task_id, task_revision,
  executor_id, process_status)
VALUES(?,?,?,?,?,?,?,?)
''',
      [
        attempt.attemptId,
        attempt.caseId,
        attempt.planId,
        attempt.planVersion,
        attempt.taskId,
        attempt.taskRevision,
        attempt.executorId,
        attempt.processStatus,
      ],
    );
  }

  CaseTimeline caseTimeline(String caseId) {
    final item = caseById(caseId);
    if (item == null) throw StateError('Unknown research case');
    return CaseTimeline(
      researchCase: item,
      plans: db
          .select(
            'SELECT * FROM plan_versions WHERE case_id=? ORDER BY plan_id, version',
            [caseId],
          )
          .map(_planFrom)
          .toList(),
      attempts: db
          .select(
            'SELECT * FROM execution_attempts WHERE case_id=? ORDER BY rowid',
            [caseId],
          )
          .map(_attemptFrom)
          .toList(),
      events: db
          .select(
            'SELECT * FROM case_events WHERE case_id=? ORDER BY position',
            [caseId],
          )
          .map(_eventFrom)
          .toList(),
    );
  }

  void _requireCase(String caseId) {
    if (caseById(caseId) == null) throw StateError('Unknown research case');
  }

  ResearchCase _caseFrom(Row row) => ResearchCase(
    id: row['id'] as String,
    projectId: row['project_id'] as String,
    question: row['question'] as String,
    methodCommit: row['method_commit'] as String,
    workflowId: row['workflow_id'] as String?,
    candidates: [
      for (final item in jsonDecode(row['candidates'] as String) as List)
        SourceRef.fromJson(Map<String, dynamic>.from(item as Map)),
    ],
    processState: row['process_state'] as String,
    scientificJudgement: row['scientific_judgement'] as String,
  );

  PlanVersion _planFrom(Row row) => PlanVersion(
    planId: row['plan_id'] as String,
    version: row['version'] as int,
    caseId: row['case_id'] as String,
    parentVersion: row['parent_version'] as int?,
    reason: row['reason'] as String,
    branch: row['branch'] as String,
  );

  ExecutionAttempt _attemptFrom(Row row) => ExecutionAttempt(
    attemptId: row['id'] as String,
    caseId: row['case_id'] as String,
    planId: row['plan_id'] as String,
    planVersion: row['plan_version'] as int,
    taskId: row['task_id'] as String?,
    taskRevision: row['task_revision'] as int?,
    executorId: row['executor_id'] as String,
    processStatus: row['process_status'] as String,
  );

  CaseEvent _eventFrom(Row row) => CaseEvent(
    id: row['id'] as String,
    caseId: row['case_id'] as String,
    type: row['type'] as String,
    sourceRefs: [
      for (final item in jsonDecode(row['source_refs'] as String) as List)
        SourceRef.fromJson(Map<String, dynamic>.from(item as Map)),
    ],
    payload: Map<String, dynamic>.from(
      jsonDecode(row['payload'] as String) as Map,
    ),
    position: row['position'] as int,
  );
}
