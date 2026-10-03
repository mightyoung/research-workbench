import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:research_workbench/core/store.dart';
import 'package:research_workbench/reader/reader_page.dart';

void main() {
  testWidgets('reader saves quoted page evidence and links it to an outline', (
    tester,
  ) async {
    final temp = Directory.systemTemp.createTempSync('reader-evidence-');
    final store = WorkbenchStore.open(temp.path);
    addTearDown(() {
      store.close();
      temp.deleteSync(recursive: true);
    });
    File(p.join(temp.path, 'paper.md')).writeAsStringSync('# Study');
    store.db.execute('INSERT INTO projects VALUES(?,?,?,?)', [
      'project',
      'Study',
      '',
      '',
    ]);
    store.db.execute('INSERT INTO documents VALUES(?,?,?,?)', [
      'document',
      'project',
      'paper.md',
      'paper.md',
    ]);
    store.db.execute('INSERT INTO entries VALUES(?,?,?,?,?)', [
      'claim',
      'project',
      'claims',
      'Cohort claim',
      '{"id":"c1","rev":1}',
    ]);
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: ReaderPage(
          store: store,
          document: store.documents('project').single,
          loadMarkdown: (_) async => '# Study',
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('来源与精读笔记'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, '证据定位'), 'Methods');
    await tester.enterText(find.widgetWithText(TextField, '页码（可选）'), '5');
    await tester.enterText(
      find.widgetWithText(TextField, '原文引句（可选）'),
      'The final cohort included 42 participants.',
    );
    await tester.enterText(
      find.widgetWithText(TextField, '精读笔记 / 批注'),
      'Check the cohort size',
    );
    tester.testTextInput.hide();
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('保存笔记'),
      180,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(find.text('不关联'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('主张 · Cohort claim').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存笔记'));
    await tester.pumpAndSettle();
    final note = store.notes('document').single;
    expect(note.entryId, 'claim');
    expect(note.pageNumber, 5);
    expect(note.quote, 'The final cohort included 42 participants.');
    await tester.scrollUntilVisible(
      find.text('关联论文提纲'),
      180,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.ensureVisible(find.text('关联论文提纲'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('关联论文提纲'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, '段落标题'),
      'Methods evidence',
    );
    await tester.tap(find.text('关联'));
    await tester.pumpAndSettle();
    expect(store.outline('project').single['evidence_id'], note.id);
    expect(tester.takeException(), isNull);
  });
}
