import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:research_workbench/core/exchange.dart';
import 'package:research_workbench/core/models.dart';
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
  test(
    'a received task can be explicitly recorded and returned with data',
    () async {
      final source = Directory(p.join(temp.path, 'source'))..createSync();
      File(p.join(source.path, 'README.md')).writeAsStringSync('# Source');
      final project = await exchange.importResearch(source.path);
      final marker = File(p.join(temp.path, 'must-not-run'));
      final task = store.saveTask(
        projectId: project.id,
        title: 'Remote measurement',
        goal: 'Return measured value and raw data',
        spec: {
          'command': 'touch ${marker.path}',
          'codeReference': 'commit:abc',
        },
      );
      final taskPackage = await exchange.exportTask(task, temp.path);

      final receiver = WorkbenchStore.open(p.join(temp.path, 'receiver'));
      addTearDown(receiver.close);
      final received = await (ResearchExchange(receiver) as dynamic).importTask(
        taskPackage,
      );
      expect(received.id, task.id);
      expect(received.revision, 1);
      expect(receiver.tasks(project.id).single.title, 'Remote measurement');
      expect(marker.existsSync(), false);

      final run = (receiver as dynamic).startManualRun(received);
      expect(run.status, 'running');
      final updated = (receiver as dynamic).updateManualRun(
        run.id,
        status: 'completed',
        metrics: {'score': 0.82},
        log: 'Executed manually on the receiving device',
        conclusion: 'Promising; review the raw data',
      );
      final artifact = File(p.join(temp.path, 'raw.csv'))
        ..writeAsStringSync('step,value\n1,0.82\n');
      final resultPackage = await (ResearchExchange(receiver) as dynamic)
          .exportResult(updated, temp.path, artifactPaths: [artifact.path]);
      expect(marker.existsSync(), false);

      final imported = await exchange.importResult(resultPackage);
      expect(imported.accepted, false);
      expect(imported.taskId, task.id);
      expect(imported.taskRevision, task.revision);
      expect(imported.data['metrics']['score'], 0.82);
      expect(imported.data['conclusion'], 'Promising; review the raw data');
      expect(imported.data['artifacts'], isNotEmpty);
      final savedArtifact = imported.data['artifacts'].single['path'] as String;
      expect(
        File(
          p.join(
            store.resolvePath(imported.data['_snapshotPath'] as String),
            savedArtifact,
          ),
        ).readAsStringSync(),
        'step,value\n1,0.82\n',
      );
      store.acceptRun(imported.id);
      expect(store.runs(project.id).single.accepted, true);
    },
  );
  test(
    'result ZIP cannot leave result.json outside its hash manifest',
    () async {
      store.db.execute('INSERT INTO projects VALUES(?,?,?,?)', [
        'p',
        'Project',
        '',
        '',
      ]);
      final task = store.saveTask(
        projectId: 'p',
        title: 'Task',
        goal: 'Measure',
        spec: {},
      );
      final result = utf8.encode(
        jsonEncode({
          'format': 'research-result-v1',
          'runId': 'r-1',
          'taskId': task.id,
          'taskRevision': task.revision,
          'status': 'completed',
        }),
      );
      final manifest = utf8.encode(
        jsonEncode({
          'format': 'research-package-v1',
          'kind': 'result',
          'files': [],
        }),
      );
      final archive = Archive()
        ..addFile(ArchiveFile('result.json', result.length, result))
        ..addFile(ArchiveFile('manifest.json', manifest.length, manifest));
      final zip = File(p.join(temp.path, 'unverified-result.zip'))
        ..writeAsBytesSync(ZipEncoder().encode(archive));
      await expectLater(exchange.importResult(zip.path), throwsFormatException);
      expect(store.runs('p'), isEmpty);
    },
  );
  test('page quote note traces through an outline into the report', () async {
    final source = Directory(p.join(temp.path, 'reading'))..createSync();
    File(p.join(source.path, 'paper.md')).writeAsStringSync('# Study');
    final project = await exchange.importResearch(source.path);
    final doc = store.documents(project.id).single;
    (store as dynamic).saveNote(
      doc.id,
      'Methods',
      'Check the stated cohort size',
      pageNumber: 5,
      quote: 'The final cohort included 42 participants.',
    );
    final note = store.notes(doc.id).single as dynamic;
    expect(note.pageNumber, 5);
    expect(note.quote, 'The final cohort included 42 participants.');
    store.addOutline(project.id, 'Methods evidence', note.id as String);
    final report = File(
      await exchange.exportReport(project.id, temp.path),
    ).readAsStringSync();
    expect(report, contains('paper.md'));
    expect(report, contains('p. 5'));
    expect(report, contains('The final cohort included 42 participants.'));
    expect(report, contains(note.id as String));
  });

  test(
    're-import updates a project and keeps notes and outline links',
    () async {
      final source = Directory(p.join(temp.path, 'evolving'))..createSync();
      final claims = File(p.join(source.path, 'claims.jsonl'));
      String line(Map<String, dynamic> v) => '${jsonEncode(v)}\n';
      claims.writeAsStringSync(
        line({'id': 'c1', 'rev': 1, 'statement': 'first'}) +
            line({'id': 'c9', 'rev': 1, 'statement': 'dropped later'}),
      );
      File(p.join(source.path, 'paper.md')).writeAsStringSync('# v1');
      final project = await exchange.importResearch(source.path);
      final doc = store.documents(project.id).single;
      store.saveNote(doc.id, 'Intro', 'keep me');
      final c1 = store
          .entries(project.id)
          .firstWhere((e) => e.data['id'] == 'c1');
      store.addOutline(project.id, 'Claim', c1.id);
      store.saveProject(project.id, question: 'Q', nextStep: 'N');

      claims.writeAsStringSync(
        line({'id': 'c1', 'rev': 1, 'statement': 'first'}) +
            line({'id': 'c1', 'rev': 2, 'statement': 'revised'}),
      );
      File(p.join(source.path, 'paper.md')).writeAsStringSync('# v2');
      File(p.join(source.path, 'new.md')).writeAsStringSync('# new');
      final updated = await exchange.importResearch(
        source.path,
        intoProjectId: project.id,
      );

      expect(updated.id, project.id);
      expect(store.projects(), hasLength(1));
      expect(store.projects().single.question, 'Q');
      final entries = store.entries(project.id);
      expect(entries.map((e) => '${e.data['id']}@${e.data['rev']}').toSet(), {
        'c1@1',
        'c1@2',
      });
      expect(entries.any((e) => e.id == c1.id), isTrue);
      final latest = latestRevisions(entries).single;
      expect(latest.data['rev'], 2);
      final docs = store.documents(project.id);
      expect(docs.map((d) => d.relativePath).toSet(), {'paper.md', 'new.md'});
      // The noted v1 stays readable; v2 arrives as a new version.
      final papers = docs.where((d) => d.relativePath == 'paper.md').toList();
      expect(papers.first.id, doc.id);
      expect(File(papers.first.absolutePath).readAsStringSync(), '# v1');
      expect(File(papers.last.absolutePath).readAsStringSync(), '# v2');
      expect(store.notes(doc.id).single.text, 'keep me');
      expect(store.outline(project.id).single['evidence_id'], c1.id);
    },
  );

  test(
    're-import keeps outline-referenced records that left the source',
    () async {
      final source = Directory(p.join(temp.path, 'shrinking'))..createSync();
      File(p.join(source.path, 'README.md')).writeAsStringSync('# Kept');
      final claims = File(p.join(source.path, 'claims.jsonl'))
        ..writeAsStringSync('${jsonEncode({'title': 'no id'})}\n');
      final project = await exchange.importResearch(source.path);
      final entry = store.entries(project.id).single;
      store.addOutline(project.id, 'Cited', entry.id);
      claims.writeAsStringSync('');
      await exchange.importResearch(source.path, intoProjectId: project.id);
      expect(store.entries(project.id).single.id, entry.id);
      await expectLater(
        exchange.importResearch(source.path, intoProjectId: 'missing'),
        throwsStateError,
      );
    },
  );

  test(
    'refresh from empty or non-research material leaves project intact',
    () async {
      final source = Directory(p.join(temp.path, 'real'))..createSync();
      File(p.join(source.path, 'README.md')).writeAsStringSync('# Real');
      File(
        p.join(source.path, 'claims.jsonl'),
      ).writeAsStringSync('${jsonEncode({'id': 'c1', 'rev': 1})}\n');
      final project = await exchange.importResearch(source.path);

      final empty = Directory(p.join(temp.path, 'empty'))..createSync();
      await expectLater(
        exchange.importResearch(empty.path, intoProjectId: project.id),
        throwsFormatException,
      );
      final task = store.saveTask(
        projectId: project.id,
        title: 't',
        goal: 'g',
        spec: {},
      );
      final taskZip = await exchange.exportTask(task, temp.path);
      await expectLater(
        exchange.importResearch(taskZip, intoProjectId: project.id),
        throwsFormatException,
      );
      expect(store.entries(project.id), hasLength(1));
      expect(store.documents(project.id).single.relativePath, 'README.md');
      expect(
        Directory(p.join(store.rootPath, 'snapshots', 'research')).listSync(),
        hasLength(1),
      );
    },
  );

  test('a genuine other record is not taken over by a new claim', () async {
    final source = Directory(p.join(temp.path, 'misc'))..createSync();
    File(p.join(source.path, 'misc.jsonl')).writeAsStringSync(
      '${jsonEncode({'id': 'x', 'rev': 1, 'note': 'misc'})}\n',
    );
    final project = await exchange.importResearch(source.path);
    final misc = store.entries(project.id).single;
    store.addOutline(project.id, 'Cited', misc.id);
    File(p.join(source.path, 'claims.jsonl')).writeAsStringSync(
      '${jsonEncode({'id': 'x', 'rev': 1, 'statement': 'claim'})}\n',
    );
    await exchange.importResearch(source.path, intoProjectId: project.id);
    final entries = store.entries(project.id);
    expect(entries.firstWhere((e) => e.id == misc.id).kind, 'other');
    expect(entries.where((e) => e.kind == 'claims'), hasLength(1));
  });

  test('re-import reclassifies legacy other rows in place', () async {
    final source = Directory(p.join(temp.path, 'legacy'))..createSync();
    final tension = {'id': 't1', 'rev': 1, 'observation': 'state leak'};
    File(
      p.join(source.path, 'tensions.jsonl'),
    ).writeAsStringSync('${jsonEncode(tension)}\n');
    final project = await exchange.importResearch(source.path);
    final entry = store.entries(project.id).single;
    // Simulate an import made before tensions were a recognised kind.
    store.db.execute("UPDATE entries SET kind='other' WHERE id=?", [entry.id]);
    store.addOutline(project.id, 'Cited', entry.id);
    await exchange.importResearch(source.path, intoProjectId: project.id);
    final after = store.entries(project.id).single;
    expect(after.id, entry.id);
    expect(after.kind, 'tensions');
  });

  test('cited records cannot change content under the same revision', () async {
    final source = Directory(p.join(temp.path, 'mutating'))..createSync();
    final claims = File(p.join(source.path, 'claims.jsonl'));
    String lines(String cited, String other) =>
        '${jsonEncode({'id': 'c1', 'rev': 1, 'statement': cited})}\n'
        '${jsonEncode({'id': 'c2', 'rev': 1, 'statement': other})}\n';
    claims.writeAsStringSync(lines('original', 'draft'));
    final project = await exchange.importResearch(source.path);
    final c1 = store
        .entries(project.id)
        .firstWhere((e) => e.data['id'] == 'c1');
    store.addOutline(project.id, 'Cited', c1.id);

    claims.writeAsStringSync(lines('original', 'typo fixed'));
    await exchange.importResearch(source.path, intoProjectId: project.id);
    String statement(String id) => store
        .entries(project.id)
        .firstWhere((e) => e.data['id'] == id)
        .data['statement'];
    expect(statement('c2'), 'typo fixed');

    claims.writeAsStringSync(lines('silently rewritten', 'typo fixed'));
    await expectLater(
      exchange.importResearch(source.path, intoProjectId: project.id),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('c1'),
        ),
      ),
    );
    expect(statement('c1'), 'original');
  });

  test(
    'a changed document keeps the version its notes were written on',
    () async {
      final source = Directory(p.join(temp.path, 'versions'))..createSync();
      final noted = File(p.join(source.path, 'noted.md'))
        ..writeAsStringSync('v1');
      final plain = File(p.join(source.path, 'plain.md'))
        ..writeAsStringSync('v1');
      final project = await exchange.importResearch(source.path);
      final docs = store.documents(project.id);
      final notedDoc = docs.firstWhere((d) => d.relativePath == 'noted.md');
      final plainDoc = docs.firstWhere((d) => d.relativePath == 'plain.md');
      store.saveNote(notedDoc.id, 'p.1', 'about v1', quote: 'v1');

      noted.writeAsStringSync('v2');
      plain.writeAsStringSync('v2');
      await exchange.importResearch(source.path, intoProjectId: project.id);
      final after = store.documents(project.id);
      final notedVersions = after.where((d) => d.relativePath == 'noted.md');
      expect(notedVersions, hasLength(2));
      expect(
        File(
          notedVersions.firstWhere((d) => d.id == notedDoc.id).absolutePath,
        ).readAsStringSync(),
        'v1',
      );
      expect(notedVersions.last.id, isNot(notedDoc.id));
      expect(File(notedVersions.last.absolutePath).readAsStringSync(), 'v2');
      final plainAfter = after.singleWhere((d) => d.relativePath == 'plain.md');
      expect(plainAfter.id, plainDoc.id);
      expect(File(plainAfter.absolutePath).readAsStringSync(), 'v2');

      await exchange.importResearch(source.path, intoProjectId: project.id);
      expect(
        store.documents(project.id).where((d) => d.relativePath == 'noted.md'),
        hasLength(2),
        reason: 'an unchanged refresh adds no further versions',
      );
    },
  );

  test('duplicate source revisions are skipped or rejected', () async {
    final source = Directory(p.join(temp.path, 'dupes'))..createSync();
    final claims = File(p.join(source.path, 'claims.jsonl'));
    final a = jsonEncode({'id': 'c1', 'rev': 1, 'statement': 'a'});
    final b = jsonEncode({'id': 'c1', 'rev': 1, 'statement': 'b'});
    claims.writeAsStringSync('$a\n$a\n');
    final project = await exchange.importResearch(source.path);
    expect(store.entries(project.id), hasLength(1));
    claims.writeAsStringSync('$a\n$b\n');
    await expectLater(
      exchange.importResearch(source.path, intoProjectId: project.id),
      throwsFormatException,
    );
    expect(store.entries(project.id).single.data['statement'], 'a');
  });

  test('existing v3 reading notes gain empty page and quote fields', () {
    final root = p.join(temp.path, 'v3-notes');
    Directory(root).createSync();
    final legacy = sqlite3.open(p.join(root, 'workbench.sqlite'));
    legacy.execute('''
CREATE TABLE projects(id TEXT PRIMARY KEY,title TEXT,question TEXT,next_step TEXT);
CREATE TABLE documents(id TEXT PRIMARY KEY,project_id TEXT,relative_path TEXT,snapshot_path TEXT);
CREATE TABLE notes(id TEXT PRIMARY KEY,document_id TEXT,locator TEXT,text TEXT);
INSERT INTO projects VALUES('p','Project','','');
INSERT INTO documents VALUES('d','p','paper.md','paper.md');
INSERT INTO notes VALUES('n','d','Section 2','Legacy note');
PRAGMA user_version=3;
''');
    legacy.close();
    final migrated = WorkbenchStore.open(root);
    addTearDown(migrated.close);
    final note = migrated.notes('d').single;
    expect(note.text, 'Legacy note');
    expect(note.pageNumber, isNull);
    expect(note.quote, isEmpty);
    expect(WorkbenchStore.schemaVersion, 5);
  });
}
