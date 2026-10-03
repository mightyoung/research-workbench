import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:research_workbench/app/workbench_app.dart';
import 'package:research_workbench/core/exchange.dart';
import 'package:research_workbench/core/store.dart';

Finder field(String label) => find.byWidgetPredicate(
  (widget) => widget is TextField && widget.decoration?.labelText == label,
);

Future<void> settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
}

void main() {
  late Directory temp;
  late WorkbenchStore store;
  late String projectId;
  setUp(() async {
    temp = Directory.systemTemp.createTempSync('workbench-ui-');
    store = WorkbenchStore.open(p.join(temp.path, 'app'));
    final source = Directory(p.join(temp.path, 'fixture'))..createSync();
    File(p.join(source.path, 'README.md')).writeAsStringSync(
      '# Reading fixture\n\nEvidence must remain conditional.\n',
    );
    File(p.join(source.path, 'papers.jsonl')).writeAsStringSync(
      '${jsonEncode({'id': 'paper-1', 'title': 'Fixture paper', 'year': 2026, 'status': 'needs_review', 'doi': '10.example/paper'})}\n',
    );
    File(p.join(source.path, 'claims.jsonl')).writeAsStringSync(
      '${jsonEncode({
        'id': 'claim-1',
        'title': 'Conditional evidence',
        'statement': 'Needs replication',
        'status': 'needs_review',
        'rev': 2,
        'locator': {'path': 'README.md', 'section': 'Reading fixture'},
      })}\n',
    );
    projectId = (await ResearchExchange(store).importResearch(source.path)).id;
  });
  tearDown(() {
    store.close();
    temp.deleteSync(recursive: true);
  });

  for (final size in [const Size(1280, 900), const Size(390, 844)]) {
    final wide = size.width > 720;
    testWidgets('library, metadata, reading and notes at $size', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      await tester.pumpWidget(
        WorkbenchApp(
          store: store,
          loadMarkdown: (path) => Future.value(File(path).readAsStringSync()),
        ),
      );
      await settle(tester);
      expect(find.text('当前研究'), findsOneWidget);
      await tester.tap(
        wide ? find.text('文库与证据') : find.byType(NavigationDestination).at(1),
      );
      await settle(tester);
      await tester.tap(find.text('Fixture paper'));
      await settle(tester);
      expect(find.textContaining('needs_review'), findsWidgets);
      expect(find.textContaining('10.example/paper'), findsWidgets);
      expect(
        store.entries(projectId, kind: 'papers').single.data['status'],
        'needs_review',
      );
      await tester.tap(find.text('关闭'));
      await settle(tester);
      await tester.tap(find.text('文件'));
      await settle(tester);
      await tester.tap(find.text('README.md').first);
      await tester.runAsync(
        () async => Future<void>.delayed(const Duration(milliseconds: 80)),
      );
      await settle(tester);
      expect(
        tester.widget<Markdown>(find.byType(Markdown)).data,
        contains('Evidence must remain conditional.'),
      );
      if (!wide) {
        await tester.tap(find.byTooltip('来源与精读笔记'));
        await settle(tester);
      }
      await tester.ensureVisible(field('证据定位'));
      await tester.enterText(field('证据定位'), 'section 1');
      await tester.ensureVisible(field('精读笔记 / 批注'));
      await tester.enterText(
        field('精读笔记 / 批注'),
        'Check independent replication',
      );
      await tester.ensureVisible(find.text('保存笔记'));
      await tester.tap(find.text('保存笔记'));
      await settle(tester);
      expect(
        store.notes(store.documents(projectId).single.id).single.text,
        'Check independent replication',
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('task drafts save immutable revisions at $size', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      await tester.pumpWidget(
        WorkbenchApp(
          store: store,
          loadMarkdown: (path) => Future.value(File(path).readAsStringSync()),
        ),
      );
      await settle(tester);
      await tester.tap(
        wide ? find.text('研究任务') : find.byType(NavigationDestination).at(2),
      );
      await settle(tester);
      await tester.tap(find.text('创建研究 / 实验任务'));
      await settle(tester);
      await tester.enterText(field('任务名称'), 'Compare shared input');
      await tester.enterText(field('问题与预期结论范围'), 'Estimate only this fixture');
      await tester.enterText(
        field('参数、数据、代码、环境与预期产物（JSON）'),
        '{"parameters":{"seed":7},"codeReference":"commit:abc"}',
      );
      await tester.tap(find.text('保存规格'));
      await settle(tester);
      final first = store.tasks(projectId).single;
      expect(first.revision, 1);
      expect(first.spec['parameters'], {'seed': 7});
      await tester.tap(find.text('编辑并保存新修订'));
      await settle(tester);
      await tester.enterText(field('问题与预期结论范围'), 'Revised scope');
      await tester.tap(find.text('保存规格'));
      await settle(tester);
      expect(store.tasks(projectId).single.revision, 2);
      expect(
        store.taskRevision(first.id, 1)!.goal,
        'Estimate only this fixture',
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('returned run requires explicit evidence acceptance at $size', (
      tester,
    ) async {
      final task = store.saveTask(
        projectId: projectId,
        title: 'Fixture run',
        goal: 'Test evidence workflow',
        spec: {
          'parameters': {'seed': 9},
        },
      );
      final result = File(p.join(temp.path, 'result.json'))
        ..writeAsStringSync(
          jsonEncode({
            'runId': 'fixture-run',
            'taskId': task.id,
            'taskRevision': task.revision,
            'status': 'completed',
            'metrics': {'score': 0.72},
            'logs': [],
            'artifacts': [],
          }),
        );
      await tester.runAsync(
        () => ResearchExchange(store).importResult(result.path),
      );
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      await tester.pumpWidget(
        WorkbenchApp(
          store: store,
          loadMarkdown: (path) => Future.value(File(path).readAsStringSync()),
        ),
      );
      await settle(tester);
      await tester.tap(
        wide ? find.text('运行结果') : find.byType(NavigationDestination).at(3),
      );
      await settle(tester);
      expect(store.runs(projectId).single.accepted, false);
      if (!wide) {
        await tester.drag(find.byType(ListView).last, const Offset(0, -340));
        await settle(tester);
      }
      await tester.ensureVisible(find.text('确认关联为证据'));
      await tester.tap(find.text('确认关联为证据'));
      await settle(tester);
      expect(find.text('关联为研究证据'), findsOneWidget);
      expect(store.runs(projectId).single.accepted, false);
      await tester.tap(find.text('确认'));
      await settle(tester);
      expect(store.runs(projectId).single.accepted, true);
      expect(find.textContaining('已关联证据'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('research relation entry opens at $size', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      await tester.pumpWidget(WorkbenchApp(store: store));
      await settle(tester);
      await tester.tap(
        find.widgetWithIcon(OutlinedButton, Icons.device_hub_outlined).first,
      );
      await settle(tester);
      expect(find.text('搜索标题或来源 ID'), findsOneWidget);
      expect(find.textContaining('个对象'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('claim evidence links to a report outline through dialogs', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      WorkbenchApp(
        store: store,
        loadMarkdown: (path) => Future.value(File(path).readAsStringSync()),
      ),
    );
    await settle(tester);
    await tester.tap(find.text('文库与证据'));
    await settle(tester);
    await tester.tap(find.text('主张'));
    await settle(tester);
    await tester.tap(find.text('Conditional evidence'));
    await settle(tester);
    await tester.tap(find.text('关联论文提纲'));
    await settle(tester);
    await tester.enterText(field('段落标题'), 'Limitations and replication');
    await tester.tap(find.text('关联'));
    await settle(tester);
    await tester.tap(find.text('论文写作'));
    await settle(tester);
    expect(find.text('Limitations and replication'), findsOneWidget);
    expect(
      store.outline(projectId).single['evidence_id'],
      store.entries(projectId, kind: 'claims').single.id,
    );
    expect(
      store.entries(projectId, kind: 'claims').single.data['status'],
      'needs_review',
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('phone user explicitly starts and updates an execution record', (
    tester,
  ) async {
    store.saveTask(
      projectId: projectId,
      title: 'Compare results',
      goal: 'Measure and return a result',
      spec: {'command': 'manual-only'},
    );
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(WorkbenchApp(store: store));
    await settle(tester);
    await tester.tap(find.byTooltip('导入材料'));
    await settle(tester);
    expect(find.text('导入任务包'), findsOneWidget);
    await tester.tapAt(const Offset(20, 250));
    await settle(tester);
    await tester.tap(find.byType(NavigationDestination).at(2));
    await settle(tester);
    expect(find.textContaining('Compare results'), findsWidgets);
    await tester.tap(find.text('开始执行记录'));
    await settle(tester);
    await tester.tap(find.text('确认'));
    await settle(tester);
    expect(store.runs(projectId).single.status, 'running');
    await tester.tap(find.byType(NavigationDestination).at(3));
    await settle(tester);
    await tester.tap(find.text('更新执行记录'));
    await settle(tester);
    await tester.enterText(field('指标（JSON）'), '{"score":0.82}');
    await tester.enterText(field('执行日志'), 'Run completed manually');
    await tester.enterText(field('结论 / 待复审'), 'Needs replication');
    await tester.tap(find.text('保存执行记录'));
    await settle(tester);
    final run = store.runs(projectId).single;
    expect(run.data['metrics']['score'], 0.82);
    expect(run.data['conclusion'], 'Needs replication');
    expect(run.data['logs'], contains('Run completed manually'));
    expect(find.text('导出结果包'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('ZIP re-import updates the same-name project in place', (
    tester,
  ) async {
    final zip = File(p.join(temp.path, 'fixture.zip'));
    await tester.runAsync(() async {
      final claims = [
        {'id': 'claim-1', 'title': 'Conditional evidence', 'rev': 2},
        {'id': 'claim-1', 'title': 'Revised evidence', 'rev': 3},
      ].map(jsonEncode).join('\n');
      final archive = Archive()
        ..addFile(ArchiveFile.string('claims.jsonl', claims));
      zip.writeAsBytesSync(ZipEncoder().encode(archive));
    });
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      WorkbenchApp(store: store, pickImportFile: (_) async => zip.path),
    );
    await settle(tester);
    await tester.tap(find.byTooltip('导入材料'));
    await settle(tester);
    await tester.tap(find.text('导入研究 ZIP'));
    await settle(tester);
    await tester.tap(find.text('确认'));
    await settle(tester);
    await tester.tap(find.textContaining('更新「fixture」 · 同名'));
    for (
      var i = 0;
      i < 50 && find.textContaining('已更新').evaluate().isEmpty;
      i++
    ) {
      await tester.runAsync(
        () async => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    await settle(tester);
    expect(store.projects(), hasLength(1));
    await tester.tap(find.text('文库与证据'));
    await settle(tester);
    await tester.tap(find.text('主张'));
    await settle(tester);
    expect(find.text('Revised evidence'), findsOneWidget);
    expect(
      store.entries(projectId, kind: 'claims').map((e) => e.data['rev']),
      unorderedEquals([2, 3]),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('all skill record kinds are browsable with judgment fields', (
    tester,
  ) async {
    final source = Directory(p.join(temp.path, 'skill', 'research'))
      ..createSync(recursive: true);
    await tester.runAsync(() async {
      for (final log in ['papers', 'sources', 'opportunities']) {
        File(p.join(source.path, '$log.jsonl')).writeAsStringSync('');
      }
      File(p.join(source.path, 'claims.jsonl')).writeAsStringSync(
        '${jsonEncode({
          'id': 'c1',
          'rev': 1,
          'statement': 'Rework hides state',
          'evidence_kind': 'inference',
          'does_not_support': ['general SOP compliance'],
        })}\n',
      );
      File(p.join(source.path, 'tensions.jsonl')).writeAsStringSync(
        '${jsonEncode({'id': 't1', 'rev': 1, 'observation': 'Done once is not done now', 'tension_type': 'anomaly'})}\n',
      );
      await ResearchExchange(store).importResearch(source.parent.path);
    });
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(WorkbenchApp(store: store));
    await settle(tester);
    await tester.tap(find.text('文库与证据'));
    await settle(tester);
    await tester.tap(find.text('矛盾与瓶颈'));
    await settle(tester);
    expect(find.text('Done once is not done now'), findsOneWidget);
    await tester.tap(find.text('主张'));
    await settle(tester);
    expect(find.textContaining('推断'), findsOneWidget);
    await tester.tap(find.text('Rework hides state'));
    await settle(tester);
    expect(find.textContaining('不支持的结论'), findsOneWidget);
    expect(find.textContaining('general SOP compliance'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a planned experiment becomes a task, run and assessed result', (
    tester,
  ) async {
    final source = Directory(p.join(temp.path, 'plan'))..createSync();
    await tester.runAsync(() async {
      File(p.join(source.path, 'experiments.jsonl')).writeAsStringSync(
        '${jsonEncode({'id': 'e1', 'rev': 1, 'phase': 'planned', 'title': 'Rework probe', 'strongest_rival': 'past completion leaks'})}\n',
      );
      await ResearchExchange(store).importResearch(source.path);
    });
    tester.view.physicalSize = const Size(1280, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(WorkbenchApp(store: store));
    await settle(tester);
    await tester.tap(find.text('文库与证据'));
    await settle(tester);
    await tester.tap(find.text('实验计划'));
    await settle(tester);
    await tester.tap(find.text('Rework probe'));
    await settle(tester);
    await tester.tap(find.text('生成实验任务'));
    await settle(tester);
    expect(find.text('来源实验计划：e1 · r1'), findsOneWidget);
    await tester.tap(find.text('开始执行记录'));
    await settle(tester);
    await tester.tap(find.text('确认'));
    await settle(tester);
    final run = store.runs(store.projects().first.id).single;
    store.updateManualRun(
      run.id,
      status: 'completed',
      metrics: {'accuracy': 0.6},
      log: '',
      conclusion: '',
    );
    await tester.tap(find.text('运行结果'));
    await settle(tester);
    await tester.tap(find.text('评估研究结论'));
    await settle(tester);
    await tester.tap(find.text('无定论'));
    await settle(tester);
    await tester.tap(find.text('支持').last);
    await settle(tester);
    await tester.tap(find.text('结果能区分自身解释与最强对手解释'));
    await tester.enterText(field('判断理由'), 'drop only after rework');
    await tester.enterText(field('实际花费（按计划预算单位，写回 skill 时必填）'), '1');
    await tester.tap(find.text('保存评估'));
    await settle(tester);
    expect(find.textContaining('研究结论：支持 · 能区分竞争解释'), findsOneWidget);
    expect(find.text('导出给 research-workflow'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('outline sections are edited, ordered and cite several items', (
    tester,
  ) async {
    final claim = store.entries(projectId, kind: 'claims').single;
    final doc = store.documents(projectId).single;
    store.saveNote(doc.id, 'p.1', 'about the claim', entryId: claim.id);
    final note = store.notes(doc.id).single;
    store.addOutline(projectId, 'Findings', claim.id);
    store.addOutline(projectId, 'Findings', note.id);
    store.addSection(projectId, 'Limits');
    tester.view.physicalSize = const Size(1280, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(WorkbenchApp(store: store));
    await settle(tester);
    await tester.tap(find.text('论文写作'));
    await settle(tester);
    expect(find.text('Findings'), findsOneWidget);
    expect(find.byTooltip('移除此证据'), findsNWidgets(2));
    await tester.tap(find.byTooltip('编辑段落').first);
    await settle(tester);
    await tester.enterText(
      field('本段论述（证据支持什么）'),
      'Rework resets completion state.',
    );
    await tester.tap(find.text('未评估').last);
    await settle(tester);
    await tester.tap(find.text('部分支持').last);
    await settle(tester);
    await tester.tap(find.text('保存段落'));
    await settle(tester);
    expect(find.text('Rework resets completion state.'), findsOneWidget);
    expect(store.sections(projectId).first.support, 'partial');
    await tester.tap(find.byTooltip('下移').first);
    await settle(tester);
    expect(store.sections(projectId).map((s) => s.heading), [
      'Limits',
      'Findings',
    ]);
    await tester.tap(find.byTooltip('移除此证据').first);
    await settle(tester);
    expect(store.outline(projectId), hasLength(1));

    await tester.tap(find.text('文库与证据'));
    await settle(tester);
    await tester.tap(find.text('主张'));
    await settle(tester);
    await tester.tap(find.text('Conditional evidence'));
    await settle(tester);
    expect(find.text('相关精读笔记 (1)'), findsOneWidget);
    expect(find.text('about the claim'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('evidence links to an existing outline section by dropdown', (
    tester,
  ) async {
    final intro = store.addSection(projectId, 'Introduction');
    store.addSection(projectId, 'Method', level: 2);
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(WorkbenchApp(store: store));
    await settle(tester);
    await tester.tap(find.text('文库与证据'));
    await settle(tester);
    await tester.tap(find.text('主张'));
    await settle(tester);
    await tester.tap(find.text('Conditional evidence'));
    await settle(tester);
    await tester.tap(find.text('关联论文提纲'));
    await settle(tester);
    expect(field('段落标题'), findsNothing);
    await tester.tap(find.textContaining('Method'));
    await settle(tester);
    await tester.tap(find.text('Introduction').last);
    await settle(tester);
    await tester.tap(find.text('关联'));
    await settle(tester);
    final claim = store.entries(projectId, kind: 'claims').single;
    expect(store.outline(projectId).single['section_id'], intro.id);
    expect(store.outline(projectId).single['evidence_id'], claim.id);
    expect(store.sections(projectId), hasLength(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('nested outline section fits a phone screen', (tester) async {
    final section = store.addSection(projectId, 'A fairly long nested heading');
    store.updateSection(
      section.id,
      heading: section.heading,
      level: 3,
      argument: '',
      support: 'contested',
    );
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(WorkbenchApp(store: store));
    await settle(tester);
    await tester.tap(find.byType(NavigationDestination).at(4));
    await settle(tester);
    expect(find.text('A fairly long nested heading'), findsOneWidget);
    expect(find.byTooltip('删除段落'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('LAN transfer opens without starting a listener', (tester) async {
    await tester.pumpWidget(WorkbenchApp(store: store));
    await settle(tester);
    await tester.tap(find.byTooltip('局域网传输'));
    await settle(tester);
    expect(find.text('未开启共享'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
