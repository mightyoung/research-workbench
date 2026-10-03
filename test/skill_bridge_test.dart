import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
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
    store.db.execute("INSERT INTO projects VALUES('p','Fixture','','')");
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
