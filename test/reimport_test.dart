import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:research_workbench/core/exchange.dart';
import 'package:research_workbench/core/models.dart';
import 'package:research_workbench/core/research_skill.dart';
import 'package:research_workbench/core/store.dart';

import 'skill_fixture.dart';

void main() {
  late Directory temp;
  late WorkbenchStore store;
  late ResearchExchange exchange;
  setUp(() {
    temp = Directory.systemTemp.createTempSync('reimport-');
    store = WorkbenchStore.open(p.join(temp.path, 'app'));
    exchange = ResearchExchange(store);
  });
  tearDown(() {
    store.close();
    temp.deleteSync(recursive: true);
  });

  var round = 0;
  String write(Map<String, String> files) {
    final root = p.join(temp.path, 'round${round++}', 'proj');
    files.forEach((rel, text) {
      File(p.join(root, rel))
        ..createSync(recursive: true)
        ..writeAsStringSync(text);
    });
    return root;
  }

  ResearchDocument doc(String projectId, String suffix) => store
      .documents(projectId)
      .firstWhere((d) => d.relativePath.endsWith(suffix));

  test('re-import moves notes and outline links into the new snapshot', () async {
    final project = await exchange.importResearch(write(skillProject()));
    final md = doc(project.id, 'notes.md');
    final pdf = doc(project.id, 'paper.pdf');
    final landscape = doc(project.id, 'landscape.md');
    store.saveNote(md.id, '', '不变的文件');
    store.saveNote(pdf.id, 'p. 1', 'PDF 笔记', pageNumber: 1);
    store.saveNote(landscape.id, '', '会被删除的文件');
    final claim = store.entries(project.id, kind: 'claims').last;
    store.addOutline(project.id, '结果', claim.id);
    final landscapeNote = store.notes(landscape.id).single.id;
    store.addOutline(project.id, '讨论', landscapeNote);

    // Second round: notes.md changes, landscape.md disappears, claim c1@3 appended.
    final files = skillProject()
      ..['related_work/acquired/h/snap/notes.md'] = '$skillMd 新增一段'
      ..remove('landscape.md');
    files['research/claims.jsonl'] =
        '${files['research/claims.jsonl']}${jsonEncode({'schema_version': 2, 'id': 'c1', 'rev': 3, 'paper_id': 'p1-v1', 'paper_rev': 2, 'statement': '第三版', 'review_status': 'current'})}\n';
    final again = await exchange.importResearch(
      write(files),
      intoProjectId: project.id,
    );
    expect(again.id, project.id);
    expect(store.projects(), hasLength(1));

    final summary = exchange.lastReimport!;
    expect(summary.notesMoved, 2);
    expect(summary.notesNeedReview, 1);
    expect(summary.notesLeft, 1);
    expect(summary.outlineMoved, 1);
    expect(summary.outlineLeft, 0);

    // Views read only the current snapshot.
    expect(store.documents(project.id).any((d) => d.id == md.id), isFalse);
    expect(
      store.documents(project.id).any((d) => d.relativePath == 'landscape.md'),
      isFalse,
    );
    final mdNote = store.notes(doc(project.id, 'notes.md').id).single;
    expect((mdNote.text, mdNote.needsReview), ('不变的文件', true));
    final pdfNote = store.notes(doc(project.id, 'paper.pdf').id).single;
    expect(pdfNote.needsReview, isFalse);
    expect(
      revOf(
        revisionGroups(
          store.entries(project.id, kind: 'claims'),
        ).single.current,
      ),
      3,
    );

    // The old document and its file survive; the note is listed as unmigrated.
    final left = store.unmigratedNotes(project.id).single;
    expect(left.$2.text, '会被删除的文件');
    expect(File(left.$1.absolutePath).existsSync(), isTrue);

    // Outline follows c1@2 into the new snapshot; the note link is untouched.
    final outline = store.outline(project.id);
    final moved = store
        .entries(project.id)
        .firstWhere((e) => e.id == outline.first['evidence_id']);
    expect(skillRef(moved), '[claims/c1@2]');
    expect(outline.last['evidence_id'], landscapeNote);

    // Reports still resolve evidence that stayed on the old snapshot.
    store.clearNoteReview(mdNote.id);
    expect(
      store.notes(doc(project.id, 'notes.md').id).single.needsReview,
      isFalse,
    );
    final report = await File(
      await exchange.exportReport(project.id, temp.path),
    ).readAsString();
    expect(report, contains('[claims/c1@2]'));
    expect(report, contains('会被删除的文件'));
  });

  test('outline links to rewritten history stay on the old snapshot', () async {
    final project = await exchange.importResearch(write(skillProject()));
    final claim = store.entries(project.id, kind: 'claims').last;
    store.addOutline(project.id, '结果', claim.id);
    final files = skillProject();
    // Rewriting the log (against v6.5 rules) drops c1@2 entirely.
    files['research/claims.jsonl'] = files['research/claims.jsonl']!
        .split('\n')
        .first;
    await exchange.importResearch(write(files), intoProjectId: project.id);
    expect(exchange.lastReimport!.outlineLeft, 1);
    final report = await File(
      await exchange.exportReport(project.id, temp.path),
    ).readAsString();
    expect(report, contains('[claims/c1@2] ${claim.id}（旧快照'));
  });

  test(
    'directory then ZIP re-import matches by project-relative path',
    () async {
      final project = await exchange.importResearch(write(skillProject()));
      store.saveNote(doc(project.id, 'paper.pdf').id, 'p. 1', '跨格式');
      final archive = Archive();
      skillProject().forEach((rel, text) {
        final bytes = utf8.encode(text);
        archive.addFile(ArchiveFile('proj/$rel', bytes.length, bytes));
      });
      final zip = File(p.join(temp.path, 'proj.zip'))
        ..writeAsBytesSync(ZipEncoder().encode(archive));
      await exchange.importResearch(zip.path, intoProjectId: project.id);
      expect(exchange.lastReimport!.notesMoved, 1);
      expect(exchange.lastReimport!.notesLeft, 0);
      expect(store.projects().single.skillRoot, 'proj/');
    },
  );

  test('manual binding choices carry over to the same ambiguity', () async {
    final files = skillProject()
      // A second paper with the same arXiv identity makes paper.pdf ambiguous.
      ..['research/papers.jsonl'] =
          '${skillProject()['research/papers.jsonl']}${jsonEncode({'schema_version': 2, 'id': 'p1-dup', 'rev': 1, 'source_id': 's1', 'source_rev': 1, 'arxiv_id': '2301.00001', 'version': 'v1', 'title': '重复登记'})}\n';
    final project = await exchange.importResearch(write(files));
    final pdf = doc(project.id, 'paper.pdf');
    expect(
      store
          .bindings(project.id)
          .where((b) => b.documentId == pdf.id)
          .every((b) => b.ambiguous),
      isTrue,
    );
    store.confirmBinding(pdf.id, 'p1-v1');
    await exchange.importResearch(write(files), intoProjectId: project.id);
    expect(exchange.lastReimport!.bindingsKept, 1);
    final next = doc(project.id, 'paper.pdf');
    final bound = store
        .bindings(project.id)
        .where((b) => b.documentId == next.id)
        .single;
    expect(
      (bound.paperId, bound.ambiguous, bound.method),
      ('p1-v1', false, 'arxiv_manifest+manual'),
    );
  });

  test('drafts flag notes whose document changed', () async {
    final project = await exchange.importResearch(write(skillProject()));
    store.saveNote(doc(project.id, 'notes.md').id, '', '分开评估');
    final files = skillProject()
      ..['related_work/acquired/h/snap/notes.md'] = '$skillMd 改动';
    await exchange.importResearch(write(files), intoProjectId: project.id);
    final note = store.notes(doc(project.id, 'notes.md').id).single;
    final result = await exchange.exportClaimDrafts(project.id, [
      note.id,
    ], p.join(temp.path, 'out'));
    expect(result.notesNeedingReview, 1);
    expect(result.rows.single['workbench']['note_needs_review'], isTrue);
  });

  test('unknown target project is refused before copying', () async {
    expect(
      () =>
          exchange.importResearch(write(skillProject()), intoProjectId: 'nope'),
      throwsStateError,
    );
    expect(
      Directory(p.join(store.rootPath, 'snapshots')).existsSync(),
      isFalse,
    );
  });
}
