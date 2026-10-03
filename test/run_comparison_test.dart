import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:research_workbench/app/workbench_app.dart';
import 'package:research_workbench/core/store.dart';

void main() {
  testWidgets('completedManualRunCanBeAccepted', (tester) async {
    final temp = Directory.systemTemp.createTempSync('run-acceptance-');
    final store = WorkbenchStore.open(temp.path);
    addTearDown(() {
      store.close();
      temp.deleteSync(recursive: true);
    });
    store.db.execute(
      'INSERT INTO projects(id,title,question,next_step) VALUES(?,?,?,?)',
      ['project', 'Acceptance', '', ''],
    );
    final task = store.saveTask(
      projectId: 'project',
      title: 'Measure',
      goal: 'Report',
      spec: {},
    );
    final run = store.startManualRun(task);
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(WorkbenchApp(store: store));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(NavigationDestination).at(3));
    await tester.pumpAndSettle();
    expect(find.text('确认关联为证据'), findsNothing);
    store.updateManualRun(
      run.id,
      status: 'completed',
      metrics: {'score': 0.82},
      log: '',
      conclusion: 'Review',
    );
    await tester.tap(find.byType(NavigationDestination).at(0));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(NavigationDestination).at(3));
    await tester.pumpAndSettle();
    expect(find.text('确认关联为证据'), findsOneWidget);
    expect(store.runs('project').single.accepted, false);
    await tester.ensureVisible(find.text('确认关联为证据'));
    await tester.tap(find.text('确认关联为证据'));
    await tester.pumpAndSettle();
    expect(store.runs('project').single.accepted, false);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(store.runs('project').single.accepted, false);
    await tester.tap(find.text('确认关联为证据'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认'));
    await tester.pumpAndSettle();
    expect(store.runs('project').single.accepted, true);
    expect(find.text('确认关联为证据'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('only runs of the same task revision appear in one comparison', (
    tester,
  ) async {
    final temp = Directory.systemTemp.createTempSync('run-comparison-');
    final store = WorkbenchStore.open(temp.path);
    addTearDown(() {
      store.close();
      temp.deleteSync(recursive: true);
    });
    store.db.execute(
      'INSERT INTO projects(id,title,question,next_step) VALUES(?,?,?,?)',
      ['project', 'Comparison', '', ''],
    );
    final task = store.saveTask(
      projectId: 'project',
      title: 'Repeat measurement',
      goal: 'Compare the same input',
      spec: {'seed': 7},
    );
    final first = store.startManualRun(task);
    store.updateManualRun(
      first.id,
      status: 'completed',
      metrics: {'score': 0.82},
      log: '',
      conclusion: 'First reported result',
    );
    store.acceptRun(first.id);
    final second = store.startManualRun(task);
    store.updateManualRun(
      second.id,
      status: 'failed',
      metrics: {'score': 0.75},
      log: '',
      conclusion: 'Needs rerun',
    );
    final revised = store.saveTask(
      id: task.id,
      projectId: 'project',
      title: task.title,
      goal: task.goal,
      spec: {'seed': 8},
    );
    final other = store.startManualRun(revised);
    store.updateManualRun(
      other.id,
      status: 'completed',
      metrics: {'score': 99},
      log: '',
      conclusion: 'Different task revision',
    );
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(WorkbenchApp(store: store));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(NavigationDestination).at(3));
    await tester.pumpAndSettle();
    expect(find.textContaining('同任务结果比较'), findsOneWidget);
    expect(find.text('0.82'), findsOneWidget);
    expect(find.text('0.75'), findsOneWidget);
    expect(find.text('99'), findsNothing);
    expect(find.text('不自动判断优劣或科学有效性'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
