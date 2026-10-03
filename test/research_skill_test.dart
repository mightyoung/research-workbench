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
    temp = Directory.systemTemp.createTempSync('research-skill-');
    store = WorkbenchStore.open(p.join(temp.path, 'app'));
    exchange = ResearchExchange(store);
  });
  tearDown(() {
    store.close();
    temp.deleteSync(recursive: true);
  });

  Directory write(Map<String, String> files, [String name = 'proj']) {
    final root = Directory(p.join(temp.path, name));
    files.forEach((rel, text) {
      File(p.join(root.path, rel))
        ..createSync(recursive: true)
        ..writeAsStringSync(text);
    });
    return root;
  }

  test('detects v6.5 layout, skips bulky paths and groups revisions', () async {
    final project = await exchange.importResearch(write(skillProject()).path);
    expect(project.layout, 'research-skill-v2');
    expect(exchange.lastSkipped.$1, 4);
    final paths = store
        .documents(project.id)
        .map((d) => d.relativePath)
        .toSet();
    expect(
      paths,
      containsAll([
        'landscape.md',
        p.join('related_work', 'p1', 'versions', 'v1', 'paper.pdf'),
      ]),
    );
    expect(paths.any((x) => x.contains('source')), isFalse);
    expect(store.entries(project.id, kind: 'tensions'), hasLength(1));

    final papers = revisionGroups(store.entries(project.id, kind: 'papers'));
    final p1 = papers.firstWhere((g) => sourceIdOf(g.current) == 'p1-v1');
    expect(revOf(p1.current), 2);
    expect(p1.older, hasLength(1));
    expect(
      papers.firstWhere((g) => sourceIdOf(g.current) == 'p-old').retired,
      isTrue,
    );
    final c1 = revisionGroups(store.entries(project.id, kind: 'claims')).single;
    expect(c1.needsReview, isTrue);
    expect(c1.duplicate, isFalse);
    expect(latestRevisions(store.entries(project.id))['claims/c1'], 2);
  });

  test('binds papers via arXiv manifest and material_binding', () async {
    final files = skillProject();
    files['related_work/acquired/h/snap/notes.md'] = '$skillMd changed';
    final project = await exchange.importResearch(write(files).path);
    final docs = {
      for (final d in store.documents(project.id)) d.id: d.relativePath,
    };
    final bindings = {for (final b in store.bindings(project.id)) b.paperId: b};
    expect(bindings.keys, unorderedEquals(['p1-v1', 'p2']));
    expect(bindings['p1-v1']!.method, 'arxiv_manifest');
    expect(bindings['p1-v1']!.paperRev, 2);
    expect(bindings['p1-v1']!.hashOk, isTrue);
    expect(docs[bindings['p1-v1']!.documentId], endsWith('paper.pdf'));
    expect(bindings['p2']!.method, 'material_binding');
    expect(bindings['p2']!.hashOk, isFalse);
  });

  test('ambiguous matches are not bound until confirmed', () {
    final entries = [
      for (final id in ['a', 'b'])
        ResearchEntry(
          id: id,
          projectId: 'x',
          kind: 'papers',
          title: id,
          data: {'id': id, 'rev': 1, 'arxiv_id': '2301.1', 'version': 'v1'},
        ),
    ];
    final result = computeBindings(
      entries: entries,
      documents: {'related_work/s/versions/v1/paper.pdf': ('doc', 'h')},
      manifests: {
        'related_work/s/versions/v1/manifest.json': {'arxiv_id': '2301.1v1'},
      },
    );
    expect(result, hasLength(2));
    expect(result.every((b) => b.ambiguous && !b.hashOk), isTrue);
  });

  test('zip with a top-level folder keeps project-relative bindings', () async {
    final archive = Archive();
    skillProject().forEach((rel, text) {
      final bytes = utf8.encode(text);
      archive.addFile(ArchiveFile('proj/$rel', bytes.length, bytes));
    });
    final zip = File(p.join(temp.path, 'proj.zip'))
      ..writeAsBytesSync(ZipEncoder().encode(archive));
    final project = await exchange.importResearch(zip.path);
    expect(project.skillRoot, 'proj/');
    expect(exchange.lastSkipped.$1, 4);
    expect(store.bindings(project.id), hasLength(2));
  });

  test('generic folders keep the previous behaviour', () async {
    final project = await exchange.importResearch(
      write({'notes.md': '# n', 'DataSet/a.md': '# kept'}, 'plain').path,
    );
    expect(project.layout, 'generic');
    expect(store.documents(project.id), hasLength(2));
    expect(store.bindings(project.id), isEmpty);
  });

  test('tilde fences protect references; mixed markers do not close', () {
    const md = '~~~\n[claims/c1@1]\n```\n[claims/c2@1]\n~~~\n[claims/c3@1]';
    final out = linkSkillRefs(md);
    expect(out, contains('\n[claims/c1@1]\n'));
    expect(out, contains('\n[claims/c2@1]\n'));
    expect(out, endsWith('[claims/c3@1](wbref:claims/c3@1)'));
  });

  test(
    'same-named JSONL outside research/ is not an authoritative log',
    () async {
      final files = skillProject()
        ..['backup/claims.jsonl'] =
            '${jsonEncode({'schema_version': 2, 'id': 'c1', 'rev': 9, 'statement': '备份'})}\n';
      final project = await exchange.importResearch(write(files).path);
      final claims = store.entries(project.id, kind: 'claims');
      expect(claims.map(revOf), isNot(contains(9)));
      expect(revOf(revisionGroups(claims).single.current), 2);
      expect(store.entries(project.id, kind: 'other').single.title, '备份');
    },
  );

  test('links deliverable references outside code', () {
    const md =
        'See [claims/c1@2] and [papers/p1-v1@3](x).\n`[claims/c9@1]`\n```\n[claims/c8@1]\n```\n[notes/x@1]';
    final out = linkSkillRefs(md);
    expect(out, contains('[claims/c1@2](wbref:claims/c1@2)'));
    expect(out, contains('[papers/p1-v1@3](x)'));
    expect(out, contains('`[claims/c9@1]`'));
    expect(out, contains('\n[claims/c8@1]\n'));
    expect(out, endsWith('[notes/x@1]'));
    expect(parseSkillRef('wbref:claims/c1@2'), ('claims', 'c1', 2));
    expect(parseSkillRef('wbref:notes/c1@2'), isNull);
  });

  test('exports claim drafts that need human completion', () async {
    final project = await exchange.importResearch(write(skillProject()).path);
    final docs = store.documents(project.id);
    final pdf = docs.firstWhere((d) => d.isPdf);
    final md = docs.firstWhere((d) => d.relativePath.endsWith('notes.md'));
    final unbound = docs.firstWhere((d) => d.relativePath == 'landscape.md');
    store.saveNote(
      pdf.id,
      'p. 3',
      '召回不足是主要瓶颈',
      pageNumber: 3,
      quote: 'recall is the bottleneck',
      evidenceKind: 'paper_statement',
    );
    store.saveNote(
      md.id,
      '',
      '分开评估',
      quote: '召回与排序分开评估。',
      doesNotSupport: '普遍提升',
    );
    store.saveNote(unbound.id, '', '地图笔记');
    final ids = [
      for (final d in [pdf, md, unbound]) store.notes(d.id).single.id,
    ];

    final out = Directory(p.join(temp.path, 'out'));
    final result = await exchange.exportClaimDrafts(
      project.id,
      ids,
      out.path,
      now: DateTime.utc(2026, 10, 3, 8),
    );
    expect(p.basename(result.path), 'workbench-claims-20261003T080000Z.jsonl');
    expect(result.skipped.single.$2, '文档未绑定论文');
    final rows = File(result.path)
        .readAsLinesSync()
        .map((l) => jsonDecode(l) as Map<String, dynamic>)
        .toList();
    expect(rows, hasLength(2));

    final fromPdf = rows.firstWhere((r) => r['paper_id'] == 'p1-v1');
    expect(fromPdf['schema_version'], 2);
    expect(fromPdf['id'], matches(RegExp(r'^c-wb-[0-9a-f]{8}$')));
    expect(fromPdf['paper_rev'], 2);
    expect(fromPdf['basis'], 'full_text');
    expect(fromPdf['locator'], {'version': 'v1', 'pdf_page': 3, 'page': null});
    expect(fromPdf['evidence_kind'], 'paper_statement');
    expect(fromPdf['review_status'], 'needs_review');
    expect(fromPdf['material_access'], 'unchecked');
    expect(fromPdf.containsKey('text_binding'), isFalse);
    expect(fromPdf['workbench']['quote'], 'recall is the bottleneck');

    final fromMd = rows.firstWhere((r) => r['paper_id'] == 'p2');
    expect(fromMd['text_binding'], {
      'path': 'related_work/acquired/h/snap/notes.md',
      'sha256': skillSha(skillMd),
      'excerpt': '召回与排序分开评估。',
    });
    expect(fromMd['material_access'], 'available');
    expect(fromMd['does_not_support'], ['普遍提升']);
    expect(
      result.missingFields,
      containsAll([
        'locator.page',
        'supports_statement',
        'scope',
        'evidence_kind',
        'does_not_support',
      ]),
    );
    expect(result.hashMismatches, 0);

    expect(
      () => exchange.exportClaimDrafts(project.id, [ids[2]], out.path),
      throwsStateError,
    );
  });

  test('report cites research-skill records in deliverable syntax', () async {
    final project = await exchange.importResearch(write(skillProject()).path);
    final claim = store.entries(project.id, kind: 'claims').last;
    store.addOutline(project.id, '结果', claim.id);
    final report = await File(
      await exchange.exportReport(project.id, temp.path),
    ).readAsString();
    expect(report, contains('来源记录：[claims/c1@2] ${claim.id}'));
  });

  test('confirmBinding resolves ambiguity by user choice', () async {
    final project = await exchange.importResearch(write(skillProject()).path);
    final doc = store.documents(project.id).first.id;
    for (final id in ['x', 'y']) {
      store.insertBinding(
        PaperBinding(
          documentId: doc,
          paperId: id,
          paperRev: 1,
          method: 'arxiv_manifest',
          hashOk: true,
          ambiguous: true,
        ),
      );
    }
    store.confirmBinding(doc, 'y');
    final left = store
        .bindings(project.id)
        .where((b) => b.documentId == doc)
        .single;
    expect(
      (left.paperId, left.ambiguous, left.method),
      ('y', false, 'arxiv_manifest+manual'),
    );
  });
}
