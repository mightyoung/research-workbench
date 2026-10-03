import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:research_workbench/app/workbench_app.dart';
import 'package:research_workbench/core/exchange.dart';
import 'package:research_workbench/core/store.dart';

import 'skill_fixture.dart';

Future<void> settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
}

void main() {
  late Directory temp;
  late WorkbenchStore store;
  setUp(() async {
    temp = Directory.systemTemp.createTempSync('skill-ui-');
    store = WorkbenchStore.open(p.join(temp.path, 'app'));
    final root = p.join(temp.path, 'proj');
    skillProject().forEach((rel, text) {
      File(p.join(root, rel))
        ..createSync(recursive: true)
        ..writeAsStringSync(text);
    });
    await ResearchExchange(store).importResearch(root);
  });
  tearDown(() {
    store.close();
    temp.deleteSync(recursive: true);
  });

  testWidgets(
    'research-skill project shows current revisions, bindings and ref links',
    (tester) async {
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
      expect(find.text('回写 research-skill'), findsOneWidget);
      expect(find.text('导出回写草稿'), findsOneWidget);
      expect(find.text('2 篇文献'), findsOneWidget);

      await tester.tap(find.text('文库与证据'));
      await settle(tester);
      expect(find.text('合成论文'), findsOneWidget);
      expect(find.text('旧标题'), findsNothing);
      expect(find.text('退役'), findsNothing);
      await tester.tap(find.text('显示已退役'));
      await settle(tester);
      expect(find.text('退役'), findsOneWidget);

      await tester.tap(find.text('主张'));
      await settle(tester);
      expect(find.text('修订后'), findsOneWidget);
      expect(find.text('初稿'), findsNothing);
      expect(find.textContaining('r2 · 2 个修订 · 待复核'), findsOneWidget);
      await tester.tap(find.text('矛盾与瓶颈'));
      await settle(tester);
      expect(find.text('增益与调优混淆'), findsOneWidget);

      await tester.tap(find.text('论文'));
      await settle(tester);
      await tester.tap(find.text('合成论文'));
      await settle(tester);
      expect(find.text('本地材料'), findsOneWidget);
      expect(find.textContaining('arXiv 下载 manifest'), findsOneWidget);
      expect(find.textContaining('[claims/c1@2]'), findsOneWidget);
      expect(find.textContaining('修订历史'), findsOneWidget);
      await tester.tap(find.text('关闭'));
      await settle(tester);

      await tester.tap(find.text('文件'));
      await settle(tester);
      await tester.tap(find.text('landscape.md').first);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 80)),
      );
      await settle(tester);
      expect(
        tester.widget<Markdown>(find.byType(Markdown)).data,
        contains('[claims/c1@2](wbref:claims/c1@2)'),
      );
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();

      await tester.tap(find.text('notes.md').first);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 80)),
      );
      await settle(tester);
      expect(find.text('绑定论文'), findsOneWidget);
      expect(find.text('获取的论文'), findsOneWidget);
      expect(find.text('证据类型（可选，回写用）'), findsOneWidget);

      // The evidence dropdown must clear together with the saved value.
      final dropdown = find.byType(DropdownButtonFormField<String>);
      await tester.ensureVisible(dropdown);
      await settle(tester);
      await tester.tap(dropdown);
      await settle(tester);
      await tester.tap(find.text('论文原述').last);
      await settle(tester);
      await tester.enterText(
        find.byWidgetPredicate(
          (w) => w is TextField && w.decoration?.labelText == '精读笔记 / 批注',
        ),
        '分开评估',
      );
      await tester.ensureVisible(find.text('保存笔记'));
      await tester.tap(find.text('保存笔记'));
      await settle(tester);
      expect(find.text('论文原述'), findsNothing);
      final doc = store
          .documents(store.projects().single.id)
          .firstWhere((d) => d.relativePath.endsWith('notes.md'));
      expect(store.notes(doc.id).single.evidenceKind, 'paper_statement');
    },
  );

  testWidgets('generic projects keep records marked active: false visible', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final generic = WorkbenchStore.open(p.join(temp.path, 'generic-app'));
    addTearDown(generic.close);
    File(p.join(temp.path, 'plain', 'papers.jsonl'))
      ..createSync(recursive: true)
      ..writeAsStringSync('{"id":"g1","title":"普通记录","active":false}\n');
    await tester.runAsync(
      () =>
          ResearchExchange(generic).importResearch(p.join(temp.path, 'plain')),
    );
    await tester.pumpWidget(WorkbenchApp(store: generic));
    await settle(tester);
    await tester.tap(find.text('文库与证据'));
    await settle(tester);
    expect(find.text('普通记录'), findsOneWidget);
    expect(find.text('显示已退役'), findsNothing);
  });
}
