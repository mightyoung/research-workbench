import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:research_workbench/app/lan_transfer_page.dart';

void main() {
  testWidgets('LAN page requires explicit share and receive actions', (
    tester,
  ) async {
    final temp = Directory.systemTemp.createTempSync('lan-page-');
    addTearDown(() => temp.deleteSync(recursive: true));
    await tester.pumpWidget(
      MaterialApp(
        home: LanTransferPage(
          rootPath: temp.path,
          onImport: (path, kind) async {},
        ),
      ),
    );
    expect(find.text('未开启共享'), findsOneWidget);
    expect(find.text('选择文件'), findsOneWidget);
    expect(find.text('开始共享'), findsOneWidget);
    expect(find.text('接收文件'), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
