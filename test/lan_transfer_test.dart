import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:research_workbench/core/lan_transfer.dart';

void main() {
  test(
    'explicit one-file LAN share needs its code and returns the frozen file',
    () async {
      final temp = Directory.systemTemp.createTempSync('lan-transfer-');
      addTearDown(() => temp.deleteSync(recursive: true));
      final source = File(p.join(temp.path, 'task.zip'))
        ..writeAsBytesSync([1, 2, 3, 4]);
      final session = await LanShareSession.start(
        file: source,
        stagingDirectory: Directory(p.join(temp.path, 'staging')),
        bindAddress: InternetAddress.loopbackIPv4,
        lifetime: const Duration(seconds: 15),
      );
      addTearDown(session.stop);
      source.writeAsBytesSync([9, 9, 9, 9]);
      final url = Uri.parse('http://127.0.0.1:${session.port}/transfer');
      await expectLater(
        LanTransferReceiver.receive(
          url: url,
          code: 'incorrect',
          destination: Directory(p.join(temp.path, 'incoming')),
        ),
        throwsFormatException,
      );
      final received = await LanTransferReceiver.receive(
        url: url,
        code: session.code,
        destination: Directory(p.join(temp.path, 'incoming')),
      );
      expect(received.path, endsWith('.zip'));
      expect(received.readAsBytesSync(), [1, 2, 3, 4]);
      expect(session.isActive, false);
    },
  );
}
