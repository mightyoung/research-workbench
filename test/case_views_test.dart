import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:research_workbench/app/case_views.dart';
import 'package:research_workbench/app/workbench_app.dart';
import 'package:research_workbench/core/case_models.dart';
import 'package:research_workbench/core/case_store.dart';
import 'package:research_workbench/core/store.dart';

Finder field(String label) => find.byWidgetPredicate(
  (widget) => widget is TextField && widget.decoration?.labelText == label,
);

Future<void> settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
}

const _sizes = [Size(1280, 900), Size(390, 844)];

void main() {
  late Directory temp;

  setUp(() => temp = Directory.systemTemp.createTempSync('case-views-'));
  tearDown(() => temp.deleteSync(recursive: true));

  testWidgets('zeroCandidatesAndMissingEvidenceDoNotDisableEditing', (
    tester,
  ) async {
    for (final size in _sizes) {
      final store = _open(temp, 'zero-${size.width}');
      addTearDown(store.close);
      final projectId = _project(store);
      _setSize(tester, size);
      await tester.pumpWidget(WorkbenchApp(store: store));
      await settle(tester);

      final open = find.widgetWithText(TextButton, '研究记录');
      await tester.ensureVisible(open);
      expect(tester.widget<TextButton>(open).onPressed, isNotNull);
      expect(store.casesFor(projectId), isEmpty);
      await tester.tap(open);
      await settle(tester);

      expect(find.textContaining('缺证据'), findsWidgets);
      expect(find.textContaining('下一步'), findsWidgets);
      expect(find.text('科学结论成立'), findsNothing);
      final save = find.widgetWithText(FilledButton, '保存案例');
      expect(tester.widget<FilledButton>(save).onPressed, isNotNull);
      await tester.enterText(field('研究问题'), '');
      await tester.enterText(field('过程'), 'writing');
      await tester.enterText(field('科学判断'), 'open');
      await settle(tester);
      expect(tester.widget<FilledButton>(save).onPressed, isNotNull);
      await tester.ensureVisible(save);
      await tester.tap(save);
      await settle(tester);

      final saved = store.casesFor(projectId).single;
      expect(saved.candidates, isEmpty);
      expect(saved.question, isEmpty);
      expect(saved.processState, 'writing');
      expect(saved.scientificJudgement, 'open');
      expect(saved.methodCommit, defaultMethodCommit);
      expect(find.text('请先完成上一阶段'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    }
  });

  testWidgets('timelineShowsReasonForkRejectRestart', (tester) async {
    for (final size in _sizes) {
      final store = _open(temp, 'time-${size.width}');
      addTearDown(store.close);
      final projectId = _project(store);
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
      store.appendEvent(
        'c',
        'reject',
        const [
          SourceRef(snapshotId: 'snap', kind: 'papers', sourceId: 'p1', rev: 4),
        ],
        {'reason': '方法不对'},
      );
      store.appendEvent('c', 'fork', const [], {'reason': '改走分支'});
      store.appendEvent('c', 'restart', const [], {'reason': '从问题重来'});

      _setSize(tester, size);
      await _pumpCase(tester, store, projectId, 'c');
      await tester.tap(find.text('计划演进'));
      await settle(tester);
      expect(find.textContaining('v1'), findsWidgets);
      expect(find.textContaining('初始计划'), findsOneWidget);
      expect(find.textContaining('main'), findsOneWidget);
      expect(find.textContaining('v2'), findsWidgets);
      expect(find.textContaining('证据不足所以分叉'), findsOneWidget);
      expect(find.textContaining('alt'), findsOneWidget);
      expect(find.textContaining('否决'), findsOneWidget);
      expect(find.textContaining('方法不对'), findsOneWidget);
      expect(find.textContaining('分叉'), findsWidgets);
      expect(find.textContaining('改走分支'), findsOneWidget);
      expect(find.textContaining('重启'), findsOneWidget);
      expect(find.textContaining('从问题重来'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    }
  });

  testWidgets('aiSuggestionShowsSourceAndCanBeEditedWithoutBecomingFact', (
    tester,
  ) async {
    for (final size in _sizes) {
      final store = _open(temp, 'ai-${size.width}');
      addTearDown(store.close);
      final projectId = _project(store);
      store.db.execute('INSERT INTO entries VALUES(?,?,?,?,?)', [
        'decoy',
        projectId,
        'papers',
        'missing-paper',
        jsonEncode({'id': 'other-paper', 'rev': 3, 'title': 'missing-paper'}),
      ]);
      store.saveCase(_case(scientificJudgement: 'not_established'));
      store.appendEvent(
        'c',
        'ai_suggestion',
        const [
          SourceRef(
            snapshotId: 'snap',
            kind: 'papers',
            sourceId: 'missing-paper',
            rev: 3,
          ),
        ],
        {'text': '也许 X 成立'},
      );
      store.appendEvent('c', 'ai_suggestion', const [], {'text': '没有来源的猜测'});

      _setSize(tester, size);
      await _pumpCase(tester, store, projectId, 'c');
      expect(find.textContaining('可修改建议'), findsWidgets);
      expect(find.textContaining('papers/missing-paper@3'), findsOneWidget);
      expect(find.textContaining('缺引用'), findsWidgets);
      expect(find.textContaining('未确认草稿'), findsOneWidget);
      expect(find.text('已确认事实'), findsNothing);
      expect(find.textContaining('没有来源的猜测'), findsOneWidget);

      await tester.enterText(field('修改建议'), '修改后的建议');
      await tester.ensureVisible(find.text('保存修改'));
      await tester.tap(find.text('保存修改'));
      await settle(tester);

      expect(store.caseById('c')!.scientificJudgement, 'not_established');
      final events = store.caseTimeline('c').events;
      expect(events.where((e) => e.type == 'ai_suggestion'), hasLength(2));
      expect(events.last.type, 'ai_suggestion_edit');
      expect(events.last.payload['text'], '修改后的建议');
      expect(events.last.sourceRefs.single.sourceId, 'missing-paper');
      expect(find.textContaining('修改后的建议'), findsOneWidget);
      expect(find.textContaining('可修改建议'), findsWidgets);
      expect(find.text('已确认事实'), findsNothing);
      expect(find.textContaining('未确认草稿'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    }
  });

  testWidgets('attemptCompletedDoesNotShowScientificSuccess', (tester) async {
    for (final size in _sizes) {
      final store = _open(temp, 'run-${size.width}');
      addTearDown(store.close);
      final projectId = _project(store);
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

      _setSize(tester, size);
      await _pumpCase(tester, store, projectId, 'c');
      await tester.tap(find.text('执行记录'));
      await settle(tester);
      expect(find.textContaining('技术运行结束'), findsOneWidget);
      expect(find.textContaining('not_established'), findsWidgets);
      expect(find.text('科学结论成立'), findsNothing);
      expect(find.textContaining('exec-1'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    }
  });
}

void _setSize(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}

WorkbenchStore _open(Directory temp, String name) =>
    WorkbenchStore.open(p.join(temp.path, name));

String _project(WorkbenchStore store) {
  store.db.execute(
    'INSERT INTO projects(id,title,question,next_step) VALUES(?,?,?,?)',
    ['p', '案例项目', '问题还没写完', ''],
  );
  return 'p';
}

ResearchCase _case({String scientificJudgement = 'open'}) => ResearchCase(
  id: 'c',
  projectId: 'p',
  question: 'Does X hold?',
  methodCommit: defaultMethodCommit,
  candidates: const [],
  processState: 'reading',
  scientificJudgement: scientificJudgement,
);

Future<void> _pumpCase(
  WidgetTester tester,
  WorkbenchStore store,
  String projectId,
  String caseId,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: CaseViews(store: store, projectId: projectId, caseId: caseId),
    ),
  );
  await settle(tester);
}
