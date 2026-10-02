import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:research_workbench/core/exchange.dart';
import 'package:research_workbench/core/store.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  late Directory temp;
  late WorkbenchStore store;
  late ResearchExchange exchange;
  setUp(() {
    temp = Directory.systemTemp.createTempSync('research-core-');
    store = WorkbenchStore.open(p.join(temp.path, 'app'));
    exchange = ResearchExchange(store);
  });
  tearDown(() {
    store.close();
    temp.deleteSync(recursive: true);
  });
  test(
    'research snapshot, task revision, result acceptance and report round trip',
    () async {
      final source = Directory(p.join(temp.path, 'source'))..createSync();
      File(
        p.join(source.path, 'README.md'),
      ).writeAsStringSync('# Source\nUnchanged original');
      File(p.join(source.path, 'claims.jsonl')).writeAsStringSync(
        '${jsonEncode({'id': 'claim-1', 'title': 'A conditional claim', 'status': 'needs_review', 'rev': 2})}\n',
      );
      final project = await exchange.importResearch(source.path);
      final entry = store.entries(project.id).single;
      expect(entry.data['status'], 'needs_review');
      expect(
        store.documents(project.id).single.absolutePath,
        startsWith(store.rootPath),
      );
      final task = store.saveTask(
        projectId: project.id,
        title: 'Evaluate',
        goal: 'Compare same inputs',
        spec: {
          'parameters': {'seed': 7},
          'dataReferences': ['dataset:1'],
          'codeReference': 'commit:abc',
          'environment': 'python 3.11',
          'expectedResults': ['scores.json'],
          'command': 'manual-only',
        },
      );
      final zip = await exchange.exportTask(task, temp.path);
      final archive = ZipDecoder().decodeBytes(await File(zip).readAsBytes());
      final template =
          jsonDecode(
                utf8.decode(
                  archive.findFile('result-template.json')!.content
                      as List<int>,
                ),
              )
              as Map<String, dynamic>;
      expect(template['taskRevision'], 1);
      final revised = store.saveTask(
        id: task.id,
        projectId: project.id,
        title: task.title,
        goal: 'New goal',
        spec: {'seed': 8},
      );
      expect(revised.revision, 2);
      expect(store.taskRevision(task.id, 1)!.goal, task.goal);
      final result = File(p.join(temp.path, 'result.json'))
        ..writeAsStringSync(
          jsonEncode({
            ...template,
            'metrics': {'accuracy': 0.75},
          }),
        );
      final run = await exchange.importResult(result.path);
      expect(run.accepted, false);
      expect(run.taskRevision, 1);
      expect((await exchange.importResult(result.path)).id, run.id);
      expect(store.runs(project.id).length, 1);
      store.acceptRun(run.id);
      store.addOutline(project.id, 'Evidence', entry.id);
      store.addOutline(project.id, 'Experiment', run.id);
      store.saveNote(
        store.documents(project.id).single.id,
        'section 1',
        'Need replication',
      );
      final report = File(
        await exchange.exportReport(project.id, temp.path),
      ).readAsStringSync();
      expect(report, contains('needs_review'));
      expect(report, contains('0.75'));
      expect(report, contains('Need replication'));
      expect(
        File(p.join(source.path, 'README.md')).readAsStringSync(),
        '# Source\nUnchanged original',
      );
      store.close();
      store = WorkbenchStore.open(p.join(temp.path, 'app'));
      expect(store.runs(project.id).single.accepted, true);
    },
  );
  test('unsafe archive is rejected without retained snapshot', () async {
    final archive = Archive()..addFile(ArchiveFile('../escape.md', 1, [65]));
    final input = File(p.join(temp.path, 'unsafe.zip'))
      ..writeAsBytesSync(ZipEncoder().encode(archive));
    await expectLater(
      exchange.importResearch(input.path),
      throwsFormatException,
    );
    expect(store.projects(), isEmpty);
    expect(
      File(p.join(store.rootPath, 'snapshots', 'escape.md')).existsSync(),
      false,
    );
  });
  test('unknown task result cannot become evidence', () async {
    final input = File(p.join(temp.path, 'result.json'))
      ..writeAsStringSync(
        jsonEncode({
          'runId': 'r1',
          'taskId': 'missing',
          'taskRevision': 1,
          'status': 'completed',
        }),
      );
    await expectLater(exchange.importResult(input.path), throwsFormatException);
  });

  test('legacy absolute paths migrate and survive a moved data directory', () {
    final oldRoot = p.join(temp.path, 'old');
    Directory(oldRoot).createSync();
    final legacy = sqlite3.open(p.join(oldRoot, 'workbench.sqlite'));
    legacy.execute(
      '''CREATE TABLE projects(id TEXT PRIMARY KEY,title TEXT,question TEXT,next_step TEXT);
CREATE TABLE documents(id TEXT PRIMARY KEY,project_id TEXT,relative_path TEXT,absolute_path TEXT);
CREATE TABLE tasks(id TEXT,revision INTEGER,project_id TEXT,title TEXT,goal TEXT,spec TEXT,PRIMARY KEY(id,revision));
CREATE TABLE runs(id TEXT PRIMARY KEY,task_id TEXT,task_revision INTEGER,status TEXT,accepted INTEGER,data TEXT);
INSERT INTO projects VALUES('p1','P','','');
INSERT INTO tasks VALUES('t1',1,'p1','T','G','{}');''',
    );
    legacy.execute('INSERT INTO documents VALUES(?,?,?,?)', [
      'd1',
      'p1',
      'notes/a.md',
      p.join(oldRoot, 'snapshots', 'research', 'snap-1', 'notes', 'a.md'),
    ]);
    legacy.execute('INSERT INTO runs VALUES(?,?,?,?,?,?)', [
      'r1',
      't1',
      1,
      'completed',
      0,
      jsonEncode({
        '_snapshotPath': p.join(oldRoot, 'snapshots', 'results', 'res-1'),
      }),
    ]);
    legacy.close();

    final newRoot = p.join(temp.path, 'moved');
    Directory(oldRoot).renameSync(newRoot);
    final moved = WorkbenchStore.open(newRoot);
    addTearDown(moved.close);
    expect(
      moved.db.select('PRAGMA user_version').first.columnAt(0),
      WorkbenchStore.schemaVersion,
    );
    expect(
      moved.documents('p1').single.absolutePath,
      p.join(
        moved.rootPath,
        'snapshots',
        'research',
        'snap-1',
        'notes',
        'a.md',
      ),
    );
    expect(
      moved.runs('p1').single.data['_snapshotPath'],
      'snapshots/results/res-1',
    );
  });

  test('a database from a newer app version is refused', () {
    final root = p.join(temp.path, 'future');
    WorkbenchStore.open(root)
      ..db.execute('PRAGMA user_version=999')
      ..close();
    expect(() => WorkbenchStore.open(root), throwsStateError);
  });
}
