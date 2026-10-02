import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:research_workbench/core/store.dart';
import 'package:research_workbench/relations/relations_page.dart';

void main() {
  testWidgets(
    'source revisions resolve while missing and ambiguous links stay explicit',
    (tester) async {
      final temp = Directory.systemTemp.createTempSync('relations-');
      final store = WorkbenchStore.open(temp.path);
      addTearDown(() {
        store.close();
        temp.deleteSync(recursive: true);
      });
      store.db.execute('INSERT INTO projects VALUES(?,?,?,?)', [
        'p',
        'Fixture',
        '',
        '',
      ]);
      void entry(
        String key,
        String kind,
        String title,
        Map<String, dynamic> data,
      ) {
        store.db.execute('INSERT INTO entries VALUES(?,?,?,?,?)', [
          key,
          'p',
          kind,
          title,
          jsonEncode(data),
        ]);
      }

      entry('local-paper', 'papers', 'Paper one', {
        'id': 'source-paper',
        'rev': 1,
      });
      entry('local-claim', 'claims', 'Precise claim', {
        'id': 'claim',
        'rev': 2,
        'paper_id': 'source-paper',
        'paper_rev': 1,
      });
      entry('candidate', 'opportunities', 'Candidate one', {
        'id': 'candidate',
        'rev': 1,
        'supports': [
          {'id': 'claim', 'rev': 2},
        ],
        'refutes': [
          {'id': 'absent', 'rev': 1},
        ],
      });
      entry('experiment', 'experiments', 'Plan one', {
        'id': 'plan',
        'rev': 1,
        'opportunity': {'id': 'candidate', 'rev': 1},
      });
      final task = store.saveTask(
        projectId: 'p',
        title: 'Task old',
        goal: '',
        spec: {},
      );
      store.saveTask(
        id: task.id,
        projectId: 'p',
        title: 'Task new',
        goal: '',
        spec: {},
      );
      store.db.execute('INSERT INTO runs VALUES(?,?,?,?,?,?)', [
        'run',
        task.id,
        1,
        'completed',
        0,
        '{}',
      ]);
      store.addOutline('p', 'Writing', 'local-claim');
      await tester.binding.setSurfaceSize(const Size(1100, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: RelationsPage(store: store, projectId: 'p'),
        ),
      );
      expect(find.text('8 个对象 · 5 条明确关联'), findsOneWidget);
      await tester.tap(find.text('Candidate one').first);
      await tester.pumpAndSettle();
      expect(find.textContaining('absent · 修订 1'), findsOneWidget);
      expect(find.textContaining('出向 · 支持依据'), findsOneWidget);
      await tester.tap(find.text('Precise claim').last);
      await tester.pumpAndSettle();
      expect(find.textContaining('出向 · 引用论文'), findsOneWidget);
      expect(find.textContaining('入向 · 写作引用'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'Task');
      await tester.pumpAndSettle();
      expect(find.text('Task old'), findsOneWidget);
      expect(find.text('Task new'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
