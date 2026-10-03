import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:research_workbench/app/reimport_panels.dart';
import 'package:research_workbench/app/workbench_app.dart';
import 'package:research_workbench/core/exchange.dart';
import 'package:research_workbench/core/models.dart';
import 'package:research_workbench/core/store.dart';

import 'skill_fixture.dart';

Future<void> settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
}

void main() {
  late Directory temp;
  late WorkbenchStore store;
  setUp(() {
    temp = Directory.systemTemp.createTempSync('reimport-ui-');
    store = WorkbenchStore.open(p.join(temp.path, 'app'));
  });
  tearDown(() {
    store.close();
    temp.deleteSync(recursive: true);
  });

  String write(String name, Map<String, String> files) {
    final root = p.join(temp.path, name, 'proj');
    files.forEach((rel, text) {
      File(p.join(root, rel))
        ..createSync(recursive: true)
        ..writeAsStringSync(text);
    });
    return root;
  }

  testWidgets('import target chooser returns new project or existing id', (
    tester,
  ) async {
    const projects = [ResearchProject(id: 'p1', title: '已有项目')];
    final results = <String?>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async =>
                results.add(await chooseImportTarget(context, '/x', projects)),
            child: const Text('go'),
          ),
        ),
      ),
    );
    for (final pick in [null, '更新：已有项目']) {
      await tester.tap(find.text('go'));
      await settle(tester);
      expect(find.text('新建项目'), findsOneWidget);
      if (pick != null) {
        await tester.tap(find.text(pick));
        await settle(tester);
      }
      await tester.tap(find.text('导入'));
      await settle(tester);
    }
    expect(results, ['', 'p1']);
  });

  testWidgets('re-imported project shows unmigrated and changed notes', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final exchange = ResearchExchange(store);
    await tester.runAsync(() async {
      final project = await exchange.importResearch(
        write('one', skillProject()),
      );
      for (final d in store.documents(project.id)) {
        if (d.relativePath.endsWith('.md')) {
          store.saveNote(d.id, '', '笔记 ${p.basename(d.relativePath)}');
        }
      }
      final files = skillProject()
        ..['related_work/acquired/h/snap/notes.md'] = '$skillMd 改动'
        ..remove('landscape.md');
      await exchange.importResearch(
        write('two', files),
        intoProjectId: project.id,
      );
    });
    await tester.pumpWidget(
      WorkbenchApp(
        store: store,
        loadMarkdown: (path) => Future.value(File(path).readAsStringSync()),
      ),
    );
    await settle(tester);
    expect(find.text('未迁移笔记（1）'), findsOneWidget);
    expect(find.text('笔记 landscape.md'), findsOneWidget);

    await tester.tap(find.text('文库与证据'));
    await settle(tester);
    await tester.tap(find.text('文件'));
    await settle(tester);
    expect(find.text('landscape.md'), findsNothing);
    await tester.tap(find.text('notes.md').first);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 80)),
    );
    await settle(tester);
    await tester.scrollUntilVisible(
      find.text('标记已复核'),
      300,
      scrollable: find
          .ancestor(of: find.text('来源与精读'), matching: find.byType(Scrollable))
          .first,
    );
    expect(find.text('再导入时原文已变更，待复核'), findsOneWidget);
    await tester.tap(find.text('标记已复核'));
    await settle(tester);
    expect(find.text('再导入时原文已变更，待复核'), findsNothing);
  });
}
