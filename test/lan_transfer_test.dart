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
  test('a paired LAN share accepts only one concurrent download', () async {
    final temp = Directory.systemTemp.createTempSync('lan-one-shot-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final source = File(p.join(temp.path, 'large.zip'));
    final writer = source.openSync(mode: FileMode.write);
    final chunk = List<int>.filled(1024 * 1024, 7);
    for (var i = 0; i < 32; i++) {
      writer.writeFromSync(chunk);
    }
    writer.closeSync();
    final session = await LanShareSession.start(
      file: source,
      stagingDirectory: Directory(p.join(temp.path, 'staging')),
      bindAddress: InternetAddress.loopbackIPv4,
      lifetime: const Duration(seconds: 15),
    );
    addTearDown(session.stop);
    final firstClient = HttpClient();
    final secondClient = HttpClient();
    addTearDown(() {
      firstClient.close(force: true);
      secondClient.close(force: true);
    });
    Future<HttpClientResponse> request(HttpClient client) async {
      final req = await client.getUrl(
        Uri.parse('http://127.0.0.1:${session.port}/transfer'),
      );
      req.headers.set('x-research-pair-code', session.code);
      return req.close();
    }

    final first = await request(firstClient);
    expect(first.statusCode, HttpStatus.ok);
    var secondSucceeded = false;
    try {
      secondSucceeded =
          (await request(secondClient)).statusCode == HttpStatus.ok;
    } on SocketException {
      // Closing the one-shot listener also refuses later attempts.
    }
    expect(secondSucceeded, false);
  });
}
