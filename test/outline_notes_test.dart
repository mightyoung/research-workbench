import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:research_workbench/core/exchange.dart';
import 'package:research_workbench/core/models.dart';
import 'package:research_workbench/core/store.dart';
import 'package:research_workbench/reader/entry_picker.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  late Directory temp;
  late WorkbenchStore store;
  late ResearchExchange exchange;
  setUp(() {
    temp = Directory.systemTemp.createTempSync('outline-notes-');
    store = WorkbenchStore.open(p.join(temp.path, 'app'));
    exchange = ResearchExchange(store);
  });
  tearDown(() {
    store.close();
    temp.deleteSync(recursive: true);
  });

  Future<(String, String, String)> fixture() async {
    final source = Directory(p.join(temp.path, 'src'))..createSync();
    File(p.join(source.path, 'paper.md')).writeAsStringSync('# Paper');
    File(p.join(source.path, 'claims.jsonl')).writeAsStringSync(
      '${jsonEncode({'id': 'c1', 'rev': 1, 'statement': 'Rework hides state'})}\n',
    );
    final project = await exchange.importResearch(source.path);
    return (
      project.id,
      store.documents(project.id).single.id,
      store.entries(project.id).single.id,
    );
  }

  test('reading notes link to research objects and protect them', () async {
    final (projectId, docId, claimId) = await fixture();
    store.saveNote(docId, 'p.3', 'supports the claim', entryId: claimId);
    store.saveNote(docId, 'p.4', 'open question');
    final notes = store.notes(docId);
    expect(notes.first.entryId, claimId);
    expect(notes.last.entryId, isNull);
    store.setNoteEntry(notes.last.id, claimId);
    expect(store.notes(docId).every((n) => n.entryId == claimId), isTrue);
    expect(
      () => store.setNoteEntry(notes.last.id, 'missing'),
      throwsStateError,
    );

    final claims = File(p.join(temp.path, 'src', 'claims.jsonl'));
    claims.writeAsStringSync(
      '${jsonEncode({'id': 'c1', 'rev': 1, 'statement': 'rewritten'})}\n',
    );
    await expectLater(
      exchange.importResearch(
        p.join(temp.path, 'src'),
        intoProjectId: projectId,
      ),
      throwsFormatException,
      reason: 'a note-cited revision cannot change silently',
    );

    claims.writeAsStringSync('');
    await exchange.importResearch(
      p.join(temp.path, 'src'),
      intoProjectId: projectId,
    );
    expect(store.entries(projectId).single.id, claimId);
  });

  test('sections group evidence, order, levels and support', () async {
    final (projectId, docId, claimId) = await fixture();
    store.saveNote(docId, 'p.3', 'excerpt', quote: 'state was reset');
    final noteId = store.notes(docId).single.id;
    store.addOutline(projectId, 'Findings', claimId);
    store.addOutline(projectId, 'Findings', noteId);
    final method = store.addSection(projectId, 'Method');
    expect(store.sections(projectId).map((s) => s.heading), [
      'Findings',
      'Method',
    ]);
    final findings = store.sections(projectId).first;
    expect(
      store.outline(projectId).where((r) => r['section_id'] == findings.id),
      hasLength(2),
    );
    store.moveSection(method.id, -1);
    expect(store.sections(projectId).map((s) => s.heading), [
      'Method',
      'Findings',
    ]);
    store.updateSection(
      findings.id,
      heading: 'Key findings',
      level: 2,
      argument: 'Rework resets completion state.',
      support: 'partial',
    );
    expect(
      store
          .outline(projectId)
          .where((r) => r['section_id'] == findings.id)
          .map((r) => r['heading']),
      everyElement('Key findings'),
    );
    expect(
      () => store.updateSection(
        findings.id,
        heading: 'x',
        level: 9,
        argument: '',
        support: 'partial',
      ),
      throwsFormatException,
    );
    expect(
      () => store.updateSection(
        findings.id,
        heading: 'x',
        level: 1,
        argument: '',
        support: 'certain',
      ),
      throwsFormatException,
    );

    final report = File(
      await exchange.exportReport(projectId, temp.path),
    ).readAsStringSync();
    expect(report.indexOf('## Method'), lessThan(report.indexOf('### Key')));
    expect(report, contains('Rework resets completion state.'));
    expect(report, contains('证据支持程度：部分支持'));
    expect(report, contains('state was reset'));
    expect(report, contains('Rework hides state'));

    final link = store.outline(projectId).first['id'] as String;
    store.removeOutline(link);
    expect(store.outline(projectId), hasLength(1));
    store.deleteSection(findings.id);
    expect(store.outline(projectId), isEmpty);
    expect(store.sections(projectId).single.heading, 'Method');
  });

  test('citing targets a section by id and ignores repeats', () async {
    final (projectId, _, claimId) = await fixture();
    final a = store.addSection(projectId, 'Same');
    final b = store.addSection(projectId, 'Same');
    store.cite(b.id, claimId);
    store.cite(b.id, claimId);
    final rows = store.outline(projectId);
    expect(rows.single['section_id'], b.id);
    expect(rows.single['heading'], 'Same');
    expect(rows.where((r) => r['section_id'] == a.id), isEmpty);
    expect(() => store.cite('missing', claimId), throwsStateError);
  });

  test('note picker keeps a link to a superseded revision visible', () {
    ResearchEntry claim(String id, int rev) => ResearchEntry(
      id: id,
      projectId: 'p',
      kind: 'claims',
      title: 'c r$rev',
      data: {'id': 'c1', 'rev': rev},
    );
    final entries = [claim('old', 1), claim('new', 2)];
    expect(noteTargets(entries).map((e) => e.id), ['new']);
    expect(noteTargets(entries, linked: 'old').map((e) => e.id), [
      'new',
      'old',
    ]);
    expect(noteTargets(entries, linked: 'new').map((e) => e.id), ['new']);
  });

  test('v4 outline rows migrate into sections by heading', () {
    final root = p.join(temp.path, 'v4');
    Directory(root).createSync();
    final legacy = sqlite3.open(p.join(root, 'workbench.sqlite'));
    legacy.execute('''
CREATE TABLE projects(id TEXT PRIMARY KEY,title TEXT,question TEXT,next_step TEXT);
CREATE TABLE documents(id TEXT PRIMARY KEY,project_id TEXT,relative_path TEXT,snapshot_path TEXT);
CREATE TABLE notes(id TEXT PRIMARY KEY,document_id TEXT,locator TEXT,text TEXT,page_number INTEGER,quoted_text TEXT NOT NULL DEFAULT '');
CREATE TABLE outline(id TEXT PRIMARY KEY,project_id TEXT,heading TEXT,evidence_id TEXT);
INSERT INTO projects VALUES('p','Project','','');
INSERT INTO outline VALUES('o1','p','Results','e1');
INSERT INTO outline VALUES('o2','p','Intro','e2');
INSERT INTO outline VALUES('o3','p','Results','e3');
PRAGMA user_version=4;
''');
    legacy.close();
    final migrated = WorkbenchStore.open(root);
    addTearDown(migrated.close);
    final sections = migrated.sections('p');
    expect(sections.map((s) => s.heading), ['Results', 'Intro']);
    expect(sections.first.support, 'unassessed');
    final rows = migrated.outline('p');
    expect(rows.where((r) => r['section_id'] == sections.first.id).length, 2);
  });
}
