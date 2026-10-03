import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:uuid/uuid.dart';
import 'models.dart';
import 'skill_bridge.dart';

class WorkbenchStore {
  WorkbenchStore._(this.rootPath, this.db);
  final String rootPath;
  final Database db;

  /// Ordered schema migrations; entry i upgrades `user_version` i to i+1.
  /// Append new steps only — never edit a shipped one.
  static final List<void Function(Database)> _migrations = [
    (db) => db.execute(
      '''CREATE TABLE IF NOT EXISTS projects(id TEXT PRIMARY KEY,title TEXT,question TEXT,next_step TEXT);
CREATE TABLE IF NOT EXISTS documents(id TEXT PRIMARY KEY,project_id TEXT REFERENCES projects(id),relative_path TEXT,absolute_path TEXT);
CREATE TABLE IF NOT EXISTS entries(id TEXT PRIMARY KEY,project_id TEXT REFERENCES projects(id),kind TEXT,title TEXT,data TEXT);
CREATE TABLE IF NOT EXISTS tasks(id TEXT,revision INTEGER,project_id TEXT REFERENCES projects(id),title TEXT,goal TEXT,spec TEXT,PRIMARY KEY(id,revision));
CREATE TABLE IF NOT EXISTS runs(id TEXT PRIMARY KEY,task_id TEXT,task_revision INTEGER,status TEXT,accepted INTEGER,data TEXT,FOREIGN KEY(task_id,task_revision) REFERENCES tasks(id,revision));
CREATE TABLE IF NOT EXISTS notes(id TEXT PRIMARY KEY,document_id TEXT REFERENCES documents(id),locator TEXT,text TEXT);
CREATE TABLE IF NOT EXISTS outline(id TEXT PRIMARY KEY,project_id TEXT REFERENCES projects(id),heading TEXT,evidence_id TEXT);''',
    ),
    _relativeSnapshotPaths,
    (db) => db.execute(
      'CREATE TABLE IF NOT EXISTS task_imports(task_id TEXT,revision INTEGER,package_path TEXT,package_sha256 TEXT,PRIMARY KEY(task_id,revision),FOREIGN KEY(task_id,revision) REFERENCES tasks(id,revision))',
    ),
    (db) => db.execute(
      "ALTER TABLE notes ADD COLUMN page_number INTEGER; ALTER TABLE notes ADD COLUMN quoted_text TEXT NOT NULL DEFAULT '';",
    ),
  ];
  static int get schemaVersion => _migrations.length;

  static WorkbenchStore open(String rootPath) {
    Directory(rootPath).createSync(recursive: true);
    final db = sqlite3.open(p.join(rootPath, 'workbench.sqlite'));
    try {
      db.execute('PRAGMA foreign_keys=ON');
      _migrate(db);
    } catch (_) {
      db.close();
      rethrow;
    }
    return WorkbenchStore._(p.absolute(rootPath), db);
  }

  static void _migrate(Database db) {
    final version = db.select('PRAGMA user_version').first.columnAt(0) as int;
    if (version > schemaVersion) {
      throw StateError(
        'Database schema v$version is newer than this app (v$schemaVersion)',
      );
    }
    for (var v = version; v < schemaVersion; v++) {
      db.execute('BEGIN');
      try {
        _migrations[v](db);
        db.execute('PRAGMA user_version=${v + 1}');
        db.execute('COMMIT');
      } catch (_) {
        db.execute('ROLLBACK');
        rethrow;
      }
    }
  }

  /// v2: snapshot paths become relative to [rootPath] so the data directory
  /// can move. Legacy absolute paths keep their `snapshots/<group>/<uuid>`
  /// tail, which is all that is needed to resolve them under a new root.
  static void _relativeSnapshotPaths(Database db) {
    String snapshotKey(String dir) {
      final parts = p.split(dir);
      return p.posix.joinAll(parts.sublist(parts.length - 3));
    }

    db.execute(
      'ALTER TABLE documents RENAME COLUMN absolute_path TO snapshot_path',
    );
    for (final r in db.select(
      'SELECT id,relative_path,snapshot_path FROM documents',
    )) {
      final full = r['snapshot_path'] as String;
      final relative = r['relative_path'] as String;
      if (!p.isAbsolute(full) || !full.endsWith(relative)) continue;
      final dir = full.substring(0, full.length - relative.length);
      db.execute('UPDATE documents SET snapshot_path=? WHERE id=?', [
        p.posix.join(snapshotKey(dir), relative.replaceAll('\\', '/')),
        r['id'],
      ]);
    }
    for (final r in db.select('SELECT id,data FROM runs')) {
      final data = decode(r['data']);
      final path = data['_snapshotPath'];
      if (path is! String || !p.isAbsolute(path)) continue;
      data['_snapshotPath'] = snapshotKey(path);
      db.execute('UPDATE runs SET data=? WHERE id=?', [
        jsonEncode(data),
        r['id'],
      ]);
    }
  }

  /// Converts a path inside [rootPath] to the portable form stored in the DB.
  String storedPath(String absolute) =>
      p.posix.joinAll(p.split(p.relative(absolute, from: rootPath)));
  String resolvePath(String stored) => p.normalize(p.join(rootPath, stored));

  void close() => db.close();
  List<ResearchProject> projects() => db
      .select('SELECT * FROM projects ORDER BY rowid DESC')
      .map(
        (r) => ResearchProject(
          id: r['id'],
          title: r['title'],
          question: r['question'],
          nextStep: r['next_step'],
        ),
      )
      .toList();
  List<ResearchDocument> documents(String projectId) => db
      .select(
        'SELECT * FROM documents WHERE project_id=? ORDER BY relative_path,rowid',
        [projectId],
      )
      .map(
        (r) => ResearchDocument(
          id: r['id'],
          projectId: r['project_id'],
          relativePath: r['relative_path'],
          absolutePath: resolvePath(r['snapshot_path']),
        ),
      )
      .toList();
  List<ResearchEntry> entries(String projectId, {String? kind}) => db
      .select(
        'SELECT * FROM entries WHERE project_id=?${kind == null ? '' : ' AND kind=?'}',
        [projectId, ?kind],
      )
      .map(
        (r) => ResearchEntry(
          id: r['id'],
          projectId: r['project_id'],
          kind: r['kind'],
          title: r['title'],
          data: decode(r['data']),
        ),
      )
      .toList();
  List<ResearchTask> tasks(String projectId) => db
      .select(
        'SELECT t.* FROM tasks t WHERE project_id=? AND revision=(SELECT MAX(revision) FROM tasks WHERE id=t.id)',
        [projectId],
      )
      .map(taskFromRow)
      .toList();
  ResearchTask taskFromRow(Row r) => ResearchTask(
    id: r['id'],
    projectId: r['project_id'],
    title: r['title'],
    goal: r['goal'],
    revision: r['revision'],
    spec: decode(r['spec']),
  );
  ResearchTask? taskRevision(String id, int revision) {
    final rows = db.select('SELECT * FROM tasks WHERE id=? AND revision=?', [
      id,
      revision,
    ]);
    return rows.isEmpty ? null : taskFromRow(rows.first);
  }

  List<ResearchRun> runs(String projectId) => db
      .select(
        'SELECT r.* FROM runs r JOIN tasks t ON t.id=r.task_id AND t.revision=r.task_revision WHERE t.project_id=?',
        [projectId],
      )
      .map(runFromRow)
      .toList();
  ResearchRun runFromRow(Row r) => ResearchRun(
    id: r['id'],
    taskId: r['task_id'],
    status: r['status'],
    taskRevision: r['task_revision'],
    accepted: r['accepted'] == 1,
    data: decode(r['data']),
  );
  List<ReadingNote> notes(String documentId) => db
      .select('SELECT * FROM notes WHERE document_id=?', [documentId])
      .map(
        (r) => ReadingNote(
          id: r['id'],
          documentId: r['document_id'],
          locator: r['locator'],
          text: r['text'],
          pageNumber: r['page_number'],
          quote: r['quoted_text'],
        ),
      )
      .toList();
  void saveProject(
    String id, {
    required String question,
    required String nextStep,
  }) => db.execute('UPDATE projects SET question=?,next_step=? WHERE id=?', [
    question,
    nextStep,
    id,
  ]);
  void saveNote(
    String documentId,
    String locator,
    String text, {
    int? pageNumber,
    String quote = '',
  }) {
    if (pageNumber != null && pageNumber < 1) {
      throw const FormatException('Page number must be positive');
    }
    db.execute(
      'INSERT INTO notes(id,document_id,locator,text,page_number,quoted_text) VALUES(?,?,?,?,?,?)',
      [const Uuid().v4(), documentId, locator, text, pageNumber, quote.trim()],
    );
  }

  ResearchTask saveTask({
    String? id,
    required String projectId,
    required String title,
    required String goal,
    required Map<String, dynamic> spec,
  }) {
    id ??= const Uuid().v4();
    final existing = db.select(
      'SELECT project_id,MAX(revision) AS revision FROM tasks WHERE id=?',
      [id],
    ).first;
    if (existing['revision'] != null && existing['project_id'] != projectId) {
      throw StateError('Task belongs to a different project');
    }
    final revision = ((existing['revision'] as int?) ?? 0) + 1;
    db.execute('INSERT INTO tasks VALUES(?,?,?,?,?,?)', [
      id,
      revision,
      projectId,
      title,
      goal,
      jsonEncode(spec),
    ]);
    return ResearchTask(
      id: id,
      projectId: projectId,
      title: title,
      goal: goal,
      revision: revision,
      spec: decode(jsonEncode(spec)),
    );
  }

  void acceptRun(String runId) =>
      db.execute('UPDATE runs SET accepted=1 WHERE id=?', [runId]);

  /// Records what a finished run means for its hypothesis; see
  /// [runAssessment]. Execution status and acceptance are left untouched.
  void assessRun(
    String runId, {
    required String result,
    required bool discriminating,
    required String reason,
    num? budgetSpent,
  }) {
    final rows = db.select('SELECT * FROM runs WHERE id=?', [runId]);
    if (rows.isEmpty) throw StateError('Unknown run');
    final run = runFromRow(rows.single);
    final data = {
      ...run.data,
      'workbench_assessment': runAssessment(
        status: run.status,
        result: result,
        discriminating: discriminating,
        reason: reason,
        budgetSpent: budgetSpent,
        at: DateTime.now(),
      ),
    };
    db.execute('UPDATE runs SET data=? WHERE id=?', [jsonEncode(data), runId]);
  }

  /// Starts a record for work the user chooses to perform in another tool.
  /// Task commands are data and are never launched by this method.
  ResearchRun startManualRun(ResearchTask task) {
    if (taskRevision(task.id, task.revision) == null) {
      throw StateError('Unknown task revision');
    }
    final id = const Uuid().v4();
    final data = <String, dynamic>{
      'format': 'research-result-v1',
      'runId': id,
      'taskId': task.id,
      'taskRevision': task.revision,
      'status': 'running',
      'metrics': <String, dynamic>{},
      'logs': <String>[],
      'artifacts': <String>[],
      'conclusion': '',
      '_localManual': true,
    };
    db.execute('INSERT INTO runs VALUES(?,?,?,?,?,?)', [
      id,
      task.id,
      task.revision,
      'running',
      0,
      jsonEncode(data),
    ]);
    return ResearchRun(
      id: id,
      taskId: task.id,
      taskRevision: task.revision,
      status: 'running',
      accepted: false,
      data: data,
    );
  }

  ResearchRun updateManualRun(
    String runId, {
    required String status,
    required Map<String, dynamic> metrics,
    required String log,
    required String conclusion,
  }) {
    if (!const {'running', 'completed', 'failed', 'blocked'}.contains(status)) {
      throw FormatException('Unsupported execution status: $status');
    }
    final rows = db.select('SELECT * FROM runs WHERE id=?', [runId]);
    if (rows.isEmpty) throw StateError('Unknown run');
    final old = runFromRow(rows.single);
    if (old.data['_localManual'] != true) {
      throw StateError('Only local manual runs can be edited');
    }
    final logs = List<String>.from(old.data['logs'] as List? ?? []);
    if (log.trim().isNotEmpty) logs.add(log.trim());
    const finished = {'completed', 'failed'};
    final data = <String, dynamic>{
      ...old.data,
      'status': status,
      'metrics': metrics,
      'logs': logs,
      'conclusion': conclusion.trim(),
    };
    // A changed outcome invalidates the earlier research judgment; appending
    // log lines does not.
    if (status != old.status ||
        jsonEncode(metrics) != jsonEncode(old.data['metrics'] ?? {}) ||
        conclusion.trim() != (old.data['conclusion'] ?? '')) {
      data.remove('workbench_assessment');
    }
    if (!finished.contains(status)) {
      data.remove('finishedAt');
    } else if (!finished.contains(old.status)) {
      data['finishedAt'] = DateTime.now().toUtc().toIso8601String();
    }
    db.execute('UPDATE runs SET status=?,data=? WHERE id=?', [
      status,
      jsonEncode(data),
      runId,
    ]);
    return ResearchRun(
      id: runId,
      taskId: old.taskId,
      taskRevision: old.taskRevision,
      status: status,
      accepted: old.accepted,
      data: data,
    );
  }

  void addOutline(String projectId, String heading, String evidenceId) =>
      db.execute('INSERT INTO outline VALUES(?,?,?,?)', [
        const Uuid().v4(),
        projectId,
        heading,
        evidenceId,
      ]);
  List<Map<String, dynamic>> outline(String projectId) => db
      .select('SELECT * FROM outline WHERE project_id=? ORDER BY rowid', [
        projectId,
      ])
      .map((r) => Map<String, dynamic>.from(r))
      .toList();
  static Map<String, dynamic> decode(String value) =>
      Map<String, dynamic>.from(jsonDecode(value) as Map);
}
