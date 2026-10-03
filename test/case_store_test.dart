import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:research_workbench/core/case_models.dart';
import 'package:research_workbench/core/case_store.dart';
import 'package:research_workbench/core/store.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  late Directory temp;
  setUp(() => temp = Directory.systemTemp.createTempSync('research-case-'));
  tearDown(() => temp.deleteSync(recursive: true));

  void insertProject(WorkbenchStore store) {
    store.db.execute(
      'INSERT INTO projects(id,title,question,next_step) VALUES(?,?,?,?)',
      ['p', 'Project', 'Does X hold?', ''],
    );
  }

  test('caseCanHaveZeroCandidatesAndSkipStages', () {
    final root = p.join(temp.path, 'fresh');
    final store = WorkbenchStore.open(root);
    addTearDown(store.close);
    expect(File(p.join(root, 'workbench.sqlite.bak-v6')).existsSync(), isFalse);
    insertProject(store);

    store.saveCase(
      const ResearchCase(
        id: 'c',
        projectId: 'p',
        question: 'Does X hold?',
        methodCommit: defaultMethodCommit,
        candidates: [],
        processState: 'writing',
        scientificJudgement: 'open',
      ),
    );

    final loaded = store.caseById('c');
    expect(loaded, isNotNull);
    expect(loaded!.candidates, isEmpty);
    expect(loaded.processState, 'writing');
    expect(loaded.scientificJudgement, 'open');
    expect(loaded.methodCommit, defaultMethodCommit);
    expect(loaded.workflowId, isNull);
    expect(store.casesFor('p').single.id, 'c');
    expect(store.casesFor('other'), isEmpty);
    expect(store.db.select('PRAGMA user_version').first.columnAt(0), 7);
  });

  test('planChangeCreatesVersionWithReasonAndBranch', () {
    final store = WorkbenchStore.open(p.join(temp.path, 'plans'));
    addTearDown(store.close);
    insertProject(store);
    store.saveCase(_case());
    store.appendPlan(
      const PlanVersion(
        planId: 'plan',
        version: 1,
        caseId: 'c',
        reason: '初始计划',
        branch: 'main',
      ),
    );
    store.appendPlan(
      const PlanVersion(
        planId: 'plan',
        version: 2,
        caseId: 'c',
        parentVersion: 1,
        reason: '证据不足所以分叉',
        branch: 'alt',
      ),
    );

    expect(
      () => store.appendPlan(
        const PlanVersion(
          planId: 'plan',
          version: 1,
          caseId: 'c',
          reason: '覆盖旧版本',
          branch: 'main',
        ),
      ),
      throwsA(anything),
    );

    final plans = store.caseTimeline('c').plans;
    expect(plans, hasLength(2));
    expect(plans.first.version, 1);
    expect(plans.first.reason, '初始计划');
    expect(plans.first.branch, 'main');
    expect(plans.first.parentVersion, isNull);
    expect(plans.last.version, 2);
    expect(plans.last.parentVersion, 1);
    expect(plans.last.reason, '证据不足所以分叉');
    expect(plans.last.branch, 'alt');
  });

  test('caseTimelineKeepsRejectedAndRestartedBranches', () {
    final store = WorkbenchStore.open(p.join(temp.path, 'timeline'));
    addTearDown(store.close);
    insertProject(store);
    store.saveCase(_case());
    store.appendPlan(
      const PlanVersion(
        planId: 'plan',
        version: 1,
        caseId: 'c',
        reason: '初始计划',
        branch: 'main',
      ),
    );
    store.appendPlan(
      const PlanVersion(
        planId: 'plan',
        version: 2,
        caseId: 'c',
        parentVersion: 1,
        reason: '改走分支',
        branch: 'alt',
      ),
    );
    const ref = SourceRef(
      snapshotId: 'snap-1',
      kind: 'papers',
      sourceId: 'paper-1',
      rev: 4,
    );
    store.appendEvent('c', 'reject', const [ref], {'reason': '方法不对'});
    store.appendEvent('c', 'fork', const [], {'reason': '改走分支'});
    store.appendEvent('c', 'restart', const [], {'reason': '从问题重来'});
    store.saveCase(_case(question: '修订后的问题'));

    final timeline = store.caseTimeline('c');
    expect(timeline.researchCase.question, '修订后的问题');
    expect(timeline.researchCase.workflowId, 'wf');
    expect(timeline.researchCase.methodCommit, v64MethodCommit);
    expect(timeline.researchCase.candidates.single.snapshotId, 'snap');
    expect(timeline.researchCase.candidates.single.kind, 'papers');
    expect(timeline.researchCase.candidates.single.sourceId, 'paper-9');
    expect(timeline.researchCase.candidates.single.rev, 2);
    expect(timeline.plans.map((plan) => plan.version), [1, 2]);
    expect(timeline.plans.map((plan) => plan.branch), ['main', 'alt']);
    expect(timeline.events.map((event) => event.type), [
      'reject',
      'fork',
      'restart',
    ]);
    expect(timeline.events.map((event) => event.payload['reason']), [
      '方法不对',
      '改走分支',
      '从问题重来',
    ]);
    expect(timeline.events.first.sourceRefs.single.snapshotId, 'snap-1');
    expect(timeline.events.first.sourceRefs.single.kind, 'papers');
    expect(timeline.events.first.sourceRefs.single.sourceId, 'paper-1');
    expect(timeline.events.first.sourceRefs.single.rev, 4);
    expect(timeline.events.map((event) => event.position), [1, 2, 3]);
  });

  test('oldV5DatabaseUpgradesWithoutChangingExistingRows', () {
    final root = p.join(temp.path, 'v5');
    Directory(root).createSync();
    _writeLegacy(root, version: 5, sections: false);

    final store = WorkbenchStore.open(root);
    addTearDown(store.close);
    _expectBusinessRows(store, entryId: null, sectionId: null);

    expect(store.db.select('PRAGMA user_version').first.columnAt(0), 7);
    expect(_count(store.db, 'research_cases'), 0);
    expect(_count(store.db, 'plan_versions'), 0);
    expect(_count(store.db, 'execution_attempts'), 0);
    expect(_count(store.db, 'case_events'), 0);

    final section = store.sections('p').single;
    expect(section.heading, 'Introduction');
    expect(section.level, 1);
    expect(section.argument, isEmpty);
    expect(section.support, 'unassessed');
    expect(store.outline('p').single['section_id'], section.id);

    final backup = _openBackup(root);
    addTearDown(backup.close);
    expect(backup.select('PRAGMA user_version').first.columnAt(0), 6);
    expect(
      backup.select('SELECT text FROM notes').single['text'],
      'Legacy note',
    );
    expect(
      backup.select(
        "SELECT name FROM sqlite_master WHERE name='research_cases'",
      ),
      isEmpty,
    );
    expect(
      backup.select('SELECT heading FROM sections').single['heading'],
      'Introduction',
    );
  });

  test('currentV6DatabaseGainsCaseTablesWithoutChangingRows', () {
    final root = p.join(temp.path, 'v6');
    Directory(root).createSync();
    _writeLegacy(root, version: 6, sections: true);

    final store = WorkbenchStore.open(root);
    addTearDown(store.close);
    _expectBusinessRows(store, entryId: 'entry-9', sectionId: 'sec-1');
    expect(store.db.select('PRAGMA user_version').first.columnAt(0), 7);
    expect(_count(store.db, 'research_cases'), 0);
    final section = store.sections('p').single;
    expect(section.id, 'sec-1');
    expect(section.level, 2);
    expect(section.argument, 'claim text');
    expect(section.support, 'partial');

    final backup = _openBackup(root);
    addTearDown(backup.close);
    expect(backup.select('PRAGMA user_version').first.columnAt(0), 6);
    expect(backup.select('SELECT id FROM sections').single['id'], 'sec-1');
    expect(
      backup.select('SELECT entry_id FROM notes').single['entry_id'],
      'entry-9',
    );
    expect(
      backup.select(
        "SELECT name FROM sqlite_master WHERE name='research_cases'",
      ),
      isEmpty,
    );
  });

  test('attemptProcessStatusIsSeparateFromScientificJudgement', () {
    final store = WorkbenchStore.open(p.join(temp.path, 'attempt'));
    addTearDown(store.close);
    insertProject(store);
    store.saveCase(_case(scientificJudgement: 'not_established'));
    store.createAttempt(
      const ExecutionAttempt(
        attemptId: 'a',
        caseId: 'c',
        planId: 'plan',
        planVersion: 1,
        executorId: 'exec-1',
        processStatus: 'completed',
      ),
    );

    final row = store.db
        .select(
          'SELECT process_status,executor_id,task_id,task_revision FROM execution_attempts',
        )
        .single;
    expect(row['process_status'], 'completed');
    expect(row['executor_id'], 'exec-1');
    expect(row['task_id'], isNull);
    expect(row['task_revision'], isNull);
    expect(store.caseById('c')!.scientificJudgement, 'not_established');
    expect(
      store.caseTimeline('c').attempts.single.processStatus,
      isNot(store.caseById('c')!.scientificJudgement),
    );
  });

  test('failedBackupAbortsMigration', () {
    final root = p.join(temp.path, 'nobak');
    Directory(root).createSync();
    final raw = sqlite3.open(p.join(root, 'workbench.sqlite'));
    raw.execute('PRAGMA user_version=6');
    raw.close();
    Directory(p.join(root, 'workbench.sqlite.bak-v6')).createSync();

    expect(() => WorkbenchStore.open(root), throwsA(isA<StateError>()));

    final check = sqlite3.open(p.join(root, 'workbench.sqlite'));
    addTearDown(check.close);
    expect(check.select('PRAGMA user_version').first.columnAt(0), 6);
    expect(
      check.select(
        "SELECT name FROM sqlite_master WHERE name='research_cases'",
      ),
      isEmpty,
    );
    expect(
      FileSystemEntity.isDirectorySync(p.join(root, 'workbench.sqlite.bak-v6')),
      isTrue,
    );
  });
}

ResearchCase _case({
  String question = 'Does X hold?',
  String scientificJudgement = 'open',
}) => ResearchCase(
  id: 'c',
  projectId: 'p',
  question: question,
  methodCommit: v64MethodCommit,
  workflowId: 'wf',
  candidates: const [
    SourceRef(snapshotId: 'snap', kind: 'papers', sourceId: 'paper-9', rev: 2),
  ],
  processState: 'reading',
  scientificJudgement: scientificJudgement,
);

void _writeLegacy(String root, {required int version, required bool sections}) {
  final db = sqlite3.open(p.join(root, 'workbench.sqlite'));
  db.execute('''
CREATE TABLE projects(
  id TEXT PRIMARY KEY, title TEXT, question TEXT, next_step TEXT,
  layout TEXT NOT NULL DEFAULT 'generic', skill_root TEXT NOT NULL DEFAULT '');
CREATE TABLE documents(
  id TEXT PRIMARY KEY, project_id TEXT REFERENCES projects(id),
  relative_path TEXT, snapshot_path TEXT, sha256 TEXT);
CREATE TABLE entries(
  id TEXT PRIMARY KEY, project_id TEXT REFERENCES projects(id),
  kind TEXT, title TEXT, data TEXT);
CREATE TABLE tasks(
  id TEXT, revision INTEGER, project_id TEXT REFERENCES projects(id),
  title TEXT, goal TEXT, spec TEXT, PRIMARY KEY(id, revision));
CREATE TABLE runs(
  id TEXT PRIMARY KEY, task_id TEXT, task_revision INTEGER, status TEXT,
  accepted INTEGER, data TEXT,
  FOREIGN KEY(task_id, task_revision) REFERENCES tasks(id, revision));
CREATE TABLE notes(
  id TEXT PRIMARY KEY, document_id TEXT REFERENCES documents(id),
  locator TEXT, text TEXT, page_number INTEGER,
  quoted_text TEXT NOT NULL DEFAULT '', evidence_kind TEXT,
  does_not_support TEXT NOT NULL DEFAULT '');
CREATE TABLE outline(
  id TEXT PRIMARY KEY, project_id TEXT REFERENCES projects(id),
  heading TEXT, evidence_id TEXT);
CREATE TABLE task_imports(
  task_id TEXT, revision INTEGER, package_path TEXT, package_sha256 TEXT,
  PRIMARY KEY(task_id, revision));
CREATE TABLE paper_bindings(
  document_id TEXT REFERENCES documents(id), paper_id TEXT, paper_rev INTEGER,
  method TEXT, hash_ok INTEGER, ambiguous INTEGER,
  PRIMARY KEY(document_id, paper_id));
''');
  if (sections) {
    db.execute('ALTER TABLE notes ADD COLUMN entry_id TEXT');
    db.execute('''
CREATE TABLE sections(
  id TEXT PRIMARY KEY, project_id TEXT REFERENCES projects(id),
  heading TEXT NOT NULL, level INTEGER NOT NULL DEFAULT 1,
  position INTEGER NOT NULL, argument TEXT NOT NULL DEFAULT '',
  support TEXT NOT NULL DEFAULT 'unassessed');
ALTER TABLE outline ADD COLUMN section_id TEXT REFERENCES sections(id);
''');
  }
  db.execute('INSERT INTO projects VALUES(?,?,?,?,?,?)', [
    'p',
    'Kept title',
    'Kept question',
    'Read section 2',
    'research-skill-v2',
    'skill/',
  ]);
  db.execute('INSERT INTO documents VALUES(?,?,?,?,?)', [
    'd',
    'p',
    'paper.md',
    'paper.md',
    'hash-1',
  ]);
  db.execute(
    sections
        ? 'INSERT INTO notes VALUES(?,?,?,?,?,?,?,?,?)'
        : 'INSERT INTO notes VALUES(?,?,?,?,?,?,?,?)',
    [
      'n',
      'd',
      'Section 2',
      'Legacy note',
      3,
      'quoted bit',
      'paper_statement',
      'does not prove Y',
      if (sections) 'entry-9',
    ],
  );
  db.execute('INSERT INTO tasks VALUES(?,?,?,?,?,?)', [
    't',
    1,
    'p',
    'Task title',
    'Goal',
    '{"metric":"auroc"}',
  ]);
  db.execute('INSERT INTO runs VALUES(?,?,?,?,?,?)', [
    'r',
    't',
    1,
    'completed',
    0,
    '{"status":"completed","metrics":{"score":0.5},"conclusion":"kept"}',
  ]);
  db.execute('INSERT INTO paper_bindings VALUES(?,?,?,?,?,?)', [
    'd',
    'paper-1',
    2,
    'hash',
    1,
    0,
  ]);
  if (sections) {
    db.execute('INSERT INTO sections VALUES(?,?,?,?,?,?,?)', [
      'sec-1',
      'p',
      'Introduction',
      2,
      1,
      'claim text',
      'partial',
    ]);
    db.execute('INSERT INTO outline VALUES(?,?,?,?,?)', [
      'o',
      'p',
      'Introduction',
      'n',
      'sec-1',
    ]);
  } else {
    db.execute('INSERT INTO outline VALUES(?,?,?,?)', [
      'o',
      'p',
      'Introduction',
      'n',
    ]);
  }
  db.execute('PRAGMA user_version=$version');
  db.close();
}

void _expectBusinessRows(
  WorkbenchStore store, {
  required String? entryId,
  required String? sectionId,
}) {
  final project = store.projects().single;
  expect(project.title, 'Kept title');
  expect(project.question, 'Kept question');
  expect(project.nextStep, 'Read section 2');
  expect(project.layout, 'research-skill-v2');
  expect(project.skillRoot, 'skill/');

  final doc = store.documents('p').single;
  expect(doc.relativePath, 'paper.md');
  expect(doc.sha256, 'hash-1');

  final note = store.notes('d').single;
  expect(note.text, 'Legacy note');
  expect(note.locator, 'Section 2');
  expect(note.pageNumber, 3);
  expect(note.quote, 'quoted bit');
  expect(note.evidenceKind, 'paper_statement');
  expect(note.doesNotSupport, 'does not prove Y');
  expect(note.entryId, entryId);

  final task = store.tasks('p').single;
  expect(task.title, 'Task title');
  expect(task.goal, 'Goal');
  expect(task.revision, 1);
  expect(task.spec['metric'], 'auroc');

  final run = store.runs('p').single;
  expect(run.status, 'completed');
  expect(run.accepted, isFalse);
  expect(run.data['conclusion'], 'kept');
  expect(run.data['metrics'], {'score': 0.5});

  final link = store.outline('p').single;
  expect(link['heading'], 'Introduction');
  expect(link['evidence_id'], 'n');
  if (sectionId != null) expect(link['section_id'], sectionId);

  final binding = store.bindings('p').single;
  expect(binding.paperId, 'paper-1');
  expect(binding.paperRev, 2);
  expect(binding.method, 'hash');
  expect(binding.hashOk, isTrue);
  expect(binding.ambiguous, isFalse);

  expect(jsonDecode(jsonEncode(run.data['metrics'])), {'score': 0.5});
}

int _count(Database db, String table) =>
    db.select('SELECT COUNT(*) AS c FROM $table').first['c'] as int;

Database _openBackup(String root) => sqlite3.open(
  p.join(root, 'workbench.sqlite.bak-v6'),
  mode: OpenMode.readOnly,
);
