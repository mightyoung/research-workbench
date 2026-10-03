import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:research_workbench/app/run_assessment_dialog.dart';
import 'package:research_workbench/core/exchange.dart';
import 'package:research_workbench/core/models.dart';
import 'package:research_workbench/core/skill_bridge.dart';
import 'package:research_workbench/core/store.dart';

void main() {
  late Directory temp;
  late WorkbenchStore store;
  setUp(() {
    temp = Directory.systemTemp.createTempSync('skill-bridge-');
    store = WorkbenchStore.open(p.join(temp.path, 'app'));
    store.db.execute(
      "INSERT INTO projects(id,title,question,next_step) VALUES('p','Fixture','','')",
    );
  });
  tearDown(() {
    store.close();
    temp.deleteSync(recursive: true);
  });

  const plan = ResearchEntry(
    id: 'local',
    projectId: 'p',
    kind: 'experiments',
    title: 'Rework state probe',
    data: {
      'id': 'e1',
      'rev': 2,
      'phase': 'planned',
      'opportunity': {'id': 'o1', 'rev': 1},
      'explanation': 'model tracks current state',
      'strongest_rival': 'model remembers past completion',
      'metric': 'state accuracy after rework',
      'predictions': [
        {'condition': 'rework', 'expect': 'drop'},
      ],
    },
  );

  test('a planned experiment becomes a task pinned to its revision', () {
    final draft = taskFromExperiment(plan);
    expect(draft.title, 'Rework state probe');
    expect(draft.goal, contains('model remembers past completion'));
    expect(draft.spec['source'], {'kind': 'experiments', 'id': 'e1', 'rev': 2});
    expect(draft.spec['opportunity'], {'id': 'o1', 'rev': 1});
    expect(draft.spec['metric'], 'state accuracy after rework');
    expect(
      () => taskFromExperiment(
        const ResearchEntry(
          id: 'x',
          projectId: 'p',
          kind: 'experiments',
          title: 'done',
          data: {'id': 'e2', 'rev': 1, 'phase': 'executed'},
        ),
      ),
      throwsFormatException,
    );
  });

  test('assessment follows research-workflow outcome rules', () {
    Map<String, dynamic> assess(String status, String result, bool d) =>
        runAssessment(
          status: status,
          result: result,
          discriminating: d,
          reason: 'why',
          budgetSpent: 1,
          at: DateTime.utc(2026, 10, 3),
        );
    expect(assess('completed', 'supporting', true)['result'], 'supporting');
    expect(
      () => assess('completed', 'supporting', false),
      throwsFormatException,
    );
    expect(() => assess('failed', 'refuting', true), throwsFormatException);
    expect(assess('failed', 'inconclusive', true)['result'], 'inconclusive');
    expect(
      () => assess('running', 'inconclusive', true),
      throwsFormatException,
    );
    expect(() => assess('completed', 'maybe', true), throwsFormatException);
  });

  test('assessed run exports as an executed experiment record', () async {
    final draft = taskFromExperiment(plan);
    final task = store.saveTask(
      projectId: 'p',
      title: draft.title,
      goal: draft.goal,
      spec: draft.spec,
    );
    final run = store.startManualRun(task);
    store.updateManualRun(
      run.id,
      status: 'completed',
      metrics: {'accuracy': 0.61, 'note': 'text is skipped'},
      log: 'ran',
      conclusion: 'drop observed',
    );
    expect(store.runs('p').single.data['finishedAt'], isA<String>());
    store.assessRun(
      run.id,
      result: 'supporting',
      discriminating: true,
      reason: 'accuracy fell only after rework',
      budgetSpent: 2,
    );
    final assessed = store.runs('p').single;
    expect(assessed.data['workbench_assessment']['result'], 'supporting');
    expect(assessed.status, 'completed');
    expect(assessed.accepted, isFalse);

    final path = await ResearchExchange(
      store,
    ).exportSkillExperiment(assessed, temp.path);
    final lines = File(path).readAsLinesSync();
    expect(lines, hasLength(1));
    final record = jsonDecode(lines.single) as Map<String, dynamic>;
    expect(record['phase'], 'executed');
    expect(record['plan_ref'], {'id': 'e1', 'rev': 2});
    expect(record['opportunity'], {'id': 'o1', 'rev': 1});
    final actual = record['actual'] as Map<String, dynamic>;
    expect(actual['measured_values'], [0.61]);
    expect(actual['result'], 'supporting');
    expect(actual['discriminating'], isTrue);
    expect(actual['execution_state'], 'completed');
    expect(actual['budget_spent'], 2);
    expect(actual['executed_at'], assessed.data['finishedAt']);
    expect(record['rev'], 1);

    Future<Map<String, dynamic>> exportAgain() async => jsonDecode(
      File(
        await ResearchExchange(
          store,
        ).exportSkillExperiment(store.runs('p').single, temp.path),
      ).readAsLinesSync().single,
    );
    final same = await exportAgain();
    expect((same['id'], same['rev']), (record['id'], 1));
    store.assessRun(
      run.id,
      result: 'inconclusive',
      discriminating: true,
      reason: 'rechecked: confound remains',
      budgetSpent: 2,
    );
    final corrected = await exportAgain();
    expect((corrected['id'], corrected['rev']), (record['id'], 2));
    expect(corrected['actual']['result'], 'inconclusive');
  });

  test('assessing an imported result keeps re-import idempotent', () async {
    final task = store.saveTask(
      projectId: 'p',
      title: 't',
      goal: 'g',
      spec: {},
    );
    final result = File(p.join(temp.path, 'result.json'))
      ..writeAsStringSync(
        jsonEncode({
          'format': 'research-result-v1',
          'runId': 'run-1',
          'taskId': task.id,
          'taskRevision': task.revision,
          'status': 'completed',
          'metrics': {'x': 1},
          'logs': <String>[],
          'artifacts': <String>[],
        }),
      );
    final exchange = ResearchExchange(store);
    await exchange.importResult(result.path);
    store.assessRun(
      'run-1',
      result: 'inconclusive',
      discriminating: false,
      reason: 'single seed',
    );
    final again = await exchange.importResult(result.path);
    expect(again.data['workbench_assessment'], isNotNull);
    expect(store.runs('p'), hasLength(1));
  });

  test('a plan behind a generated task is protected on refresh', () async {
    final source = Directory(p.join(temp.path, 'plan'))..createSync();
    final experiments = File(p.join(source.path, 'experiments.jsonl'));
    String line(String explanation) =>
        '${jsonEncode({'id': 'e1', 'rev': 1, 'phase': 'planned', 'explanation': explanation})}\n';
    experiments.writeAsStringSync(line('original'));
    File(p.join(source.path, 'README.md')).writeAsStringSync('# r');
    final exchange = ResearchExchange(store);
    final project = await exchange.importResearch(source.path);
    final plan = store.entries(project.id).single;
    final draft = taskFromExperiment(plan);
    store.saveTask(
      projectId: project.id,
      title: draft.title,
      goal: draft.goal,
      spec: draft.spec,
    );
    experiments.writeAsStringSync(line('rewritten'));
    await expectLater(
      exchange.importResearch(source.path, intoProjectId: project.id),
      throwsFormatException,
    );
    experiments.writeAsStringSync('');
    await exchange.importResearch(source.path, intoProjectId: project.id);
    expect(store.entries(project.id).single.id, plan.id);
  });

  test('runs sharing an ID prefix export distinct identities', () {
    final task = ResearchTask(
      id: 't',
      projectId: 'p',
      title: 't',
      goal: 'g',
      revision: 1,
      spec: taskFromExperiment(plan).spec,
    );
    String idFor(String runId) => executedExperiment(
      task: task,
      run: ResearchRun(
        id: runId,
        taskId: 't',
        status: 'completed',
        taskRevision: 1,
        accepted: false,
        data: {
          'metrics': {'x': 1},
          'finishedAt': '2026-10-03T08:00:00Z',
          'workbench_assessment': {
            'result': 'inconclusive',
            'discriminating': false,
            'reason': 'r',
            'budget_spent': 0,
          },
        },
      ),
      now: DateTime.utc(2026, 10, 3),
    )['id'];
    expect(idFor('seed-001-a'), isNot(idFor('seed-001-b')));
  });

  test('assessments inside a result package are not imported', () async {
    final task = store.saveTask(
      projectId: 'p',
      title: 't',
      goal: 'g',
      spec: {},
    );
    final result = File(p.join(temp.path, 'with-assessment.json'))
      ..writeAsStringSync(
        jsonEncode({
          'format': 'research-result-v1',
          'runId': 'run-x',
          'taskId': task.id,
          'taskRevision': task.revision,
          'status': 'failed',
          'metrics': <String, dynamic>{},
          'logs': <String>[],
          'artifacts': <String>[],
          'workbench_assessment': {'result': 'supporting'},
        }),
      );
    final run = await ResearchExchange(store).importResult(result.path);
    expect(run.data.containsKey('workbench_assessment'), isFalse);
  });

  testWidgets('assessment dialog opens despite an unsupported prior value', (
    tester,
  ) async {
    const run = ResearchRun(
      id: 'r',
      taskId: 't',
      status: 'completed',
      taskRevision: 1,
      accepted: false,
      data: {
        'workbench_assessment': {'result': 'bogus'},
      },
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showRunAssessmentDialog(context, run),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('无定论'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('editing outcome data drops the earlier assessment', () {
    final task = store.saveTask(
      projectId: 'p',
      title: 't',
      goal: 'g',
      spec: {},
    );
    final run = store.startManualRun(task);
    void update(Map<String, dynamic> metrics, String conclusion) =>
        store.updateManualRun(
          run.id,
          status: 'completed',
          metrics: metrics,
          log: 'more log',
          conclusion: conclusion,
        );
    void assess() => store.assessRun(
      run.id,
      result: 'inconclusive',
      discriminating: false,
      reason: 'r',
    );
    Object? assessment() => store.runs('p').single.data['workbench_assessment'];
    update({'x': 1}, 'c');
    assess();
    update({'x': 1}, 'c');
    expect(assessment(), isNotNull, reason: 'log-only edits keep it');
    update({'x': 2}, 'c');
    expect(assessment(), isNull);
    assess();
    update({'x': 2}, 'changed');
    expect(assessment(), isNull);
  });

  test('export revalidates stored assessments and finish time', () {
    final task = ResearchTask(
      id: 't',
      projectId: 'p',
      title: 't',
      goal: 'g',
      revision: 1,
      spec: taskFromExperiment(plan).spec,
    );
    Map<String, dynamic> record(
      String status,
      Map<String, dynamic> assessment, {
      String finishedAt = '2026-10-03T08:00:00Z',
    }) => executedExperiment(
      task: task,
      run: ResearchRun(
        id: 'run',
        taskId: 't',
        status: status,
        taskRevision: 1,
        accepted: false,
        data: {
          'metrics': {'x': 1},
          'finishedAt': finishedAt,
          'workbench_assessment': assessment,
        },
      ),
      now: DateTime.utc(2026, 10, 3),
    );
    const ok = {
      'result': 'supporting',
      'discriminating': true,
      'reason': 'r',
      'budget_spent': 1,
    };
    expect(record('completed', ok)['actual']['result'], 'supporting');
    for (final (status, bad) in [
      ('failed', ok),
      ('completed', {...ok, 'discriminating': false}),
      ('completed', {...ok, 'budget_spent': -1}),
      ('completed', {...ok, 'reason': ''}),
      ('completed', {...ok, 'discriminating': 'yes'}),
      ('completed', {...ok, 'result': 7}),
    ]) {
      expect(() => record(status, bad), throwsFormatException);
    }
    for (final time in [
      'yesterday',
      '2026-10-03T08:00:00',
      '2026-13-40T00:00Z',
      '2026-10-03T99:99:99Z',
      '2026-10-03T08:00:00+25:00',
    ]) {
      expect(
        () => record('completed', ok, finishedAt: time),
        throwsFormatException,
      );
    }
    final withOffset = record(
      'completed',
      ok,
      finishedAt: '2026-10-03T16:00:00+08:00',
    );
    expect(withOffset['actual']['executed_at'], '2026-10-03T16:00:00+08:00');
  });

  test(
    'export refuses runs that cannot form a valid executed record',
    () async {
      final exchange = ResearchExchange(store);
      final plain = store.saveTask(
        projectId: 'p',
        title: 'Hand-written',
        goal: 'g',
        spec: {},
      );
      final run = store.startManualRun(plain);
      store.updateManualRun(
        run.id,
        status: 'completed',
        metrics: {'x': 1},
        log: '',
        conclusion: '',
      );
      store.assessRun(
        run.id,
        result: 'inconclusive',
        discriminating: false,
        reason: 'no plan',
      );
      await expectLater(
        exchange.exportSkillExperiment(store.runs('p').single, temp.path),
        throwsFormatException,
      );
    },
  );
}
