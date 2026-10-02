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
  test(
    'LAN receiver refuses redirects before contacting another endpoint',
    () async {
      final temp = Directory.systemTemp.createTempSync('lan-redirect-');
      addTearDown(() => temp.deleteSync(recursive: true));
      final target = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final source = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        await source.close(force: true);
        await target.close(force: true);
      });
      var targetReached = false;
      target.listen((request) async {
        targetReached = true;
        request.response.write('unexpected');
        await request.response.close();
      });
      source.listen((request) async {
        request.response.statusCode = HttpStatus.found;
        request.response.headers.set(
          HttpHeaders.locationHeader,
          'http://127.0.0.1:${target.port}/transfer',
        );
        await request.response.close();
      });
      await expectLater(
        LanTransferReceiver.receive(
          url: Uri.parse('http://127.0.0.1:${source.port}/transfer'),
          code: 'chosen-by-user',
          destination: Directory(p.join(temp.path, 'received')),
        ),
        throwsFormatException,
      );
      expect(targetReached, false);
    },
  );
}
