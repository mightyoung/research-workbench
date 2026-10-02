import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

/// Serves exactly one user-selected frozen file, after an explicit start.
/// No listener exists until [start] is called by the user interface.
class LanShareSession {
  LanShareSession._(
    this._server,
    this._sessionDirectory,
    this._file,
    this.code,
  );

  static const maxBytes = 150 * 1024 * 1024;
  final HttpServer _server;
  final Directory _sessionDirectory;
  final File _file;
  final String code;
  Timer? _expiry;
  StreamSubscription<HttpRequest>? _requests;
  bool _active = true;
  bool get isActive => _active;
  int get port => _server.port;
  String get fileName => p.basename(_file.path);

  static Future<LanShareSession> start({
    required File file,
    required Directory stagingDirectory,
    InternetAddress? bindAddress,
    Duration lifetime = const Duration(minutes: 10),
  }) async {
    if (lifetime <= Duration.zero || lifetime > const Duration(minutes: 10)) {
      throw const FormatException(
        'LAN share lifetime must be at most 10 minutes',
      );
    }
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw const FormatException('Select a regular file to share');
    }
    if (await file.length() > maxBytes) {
      throw const FormatException('Selected file exceeds 150 MiB');
    }
    final directory = Directory(
      p.join(stagingDirectory.path, const Uuid().v4()),
    );
    await directory.create(recursive: true);
    try {
      final frozen = await file.copy(
        p.join(directory.path, p.basename(file.path)),
      );
      final server = await HttpServer.bind(
        bindAddress ?? InternetAddress.anyIPv4,
        0,
      );
      final random = Random.secure();
      final code = base64Url
          .encode(List<int>.generate(18, (_) => random.nextInt(256)))
          .replaceAll('=', '');
      final session = LanShareSession._(server, directory, frozen, code);
      session._requests = server.listen(session._handle);
      session._expiry = Timer(lifetime, () {
        unawaited(session.stop());
      });
      return session;
    } catch (_) {
      await directory.delete(recursive: true);
      rethrow;
    }
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    if (!_active ||
        request.method != 'GET' ||
        request.uri.path != '/transfer') {
      response.statusCode = HttpStatus.notFound;
      await response.close();
      return;
    }
    if (request.headers.value('x-research-pair-code') != code) {
      response.statusCode = HttpStatus.forbidden;
      await response.close();
      return;
    }
    try {
      response.headers.contentType = ContentType.binary;
      response.headers.set('x-file-name', Uri.encodeComponent(fileName));
      response.contentLength = await _file.length();
      await response.addStream(_file.openRead());
      await response.close();
    } finally {
      await stop();
    }
  }

  Future<void> stop() async {
    if (!_active) return;
    _active = false;
    _expiry?.cancel();
    await _requests?.cancel();
    await _server.close(force: true);
    if (await _sessionDirectory.exists()) {
      await _sessionDirectory.delete(recursive: true);
    }
  }

  static Future<List<String>> localAddresses() async {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
    );
    return <String>{
      for (final interface in interfaces)
        for (final address in interface.addresses)
          if (LanTransferReceiver.isLocalIpv4(address.address) &&
              !address.isLoopback)
            address.address,
    }.toList()..sort();
  }
}

class LanTransferReceiver {
  static const maxBytes = LanShareSession.maxBytes;

  static bool isLocalIpv4(String host) {
    final address = InternetAddress.tryParse(host);
    if (address == null || address.type != InternetAddressType.IPv4) {
      return false;
    }
    final octets = address.rawAddress;
    return octets[0] == 10 ||
        octets[0] == 127 ||
        (octets[0] == 172 && octets[1] >= 16 && octets[1] <= 31) ||
        (octets[0] == 192 && octets[1] == 168) ||
        (octets[0] == 169 && octets[1] == 254);
  }

  static Future<File> receive({
    required Uri url,
    required String code,
    required Directory destination,
  }) async {
    if (url.scheme != 'http' || url.port < 1 || !isLocalIpv4(url.host)) {
      throw const FormatException('Enter an IPv4 address on the local network');
    }
    if (code.trim().isEmpty) {
      throw const FormatException('Pair code is required');
    }
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    File? target;
    try {
      final request = await client.getUrl(
        url.replace(path: '/transfer', query: '', fragment: ''),
      );
      request.followRedirects = false;
      request.headers.set('x-research-pair-code', code.trim());
      final response = await request.close();
      if (response.statusCode == HttpStatus.forbidden) {
        throw const FormatException('Pair code was rejected');
      }
      if (response.statusCode != HttpStatus.ok ||
          response.contentLength > maxBytes) {
        throw const FormatException('LAN transfer refused or too large');
      }
      final encoded = response.headers.value('x-file-name') ?? 'received.zip';
      final name = p.basename(
        Uri.decodeComponent(encoded).replaceAll('\\', '/'),
      );
      if (name.isEmpty || name == '.' || name == '..') {
        throw const FormatException('Invalid transferred file name');
      }
      await destination.create(recursive: true);
      target = File(p.join(destination.path, '${const Uuid().v4()}-$name'));
      final sink = target.openWrite();
      var total = 0;
      try {
        await for (final chunk in response) {
          total += chunk.length;
          if (total > maxBytes) {
            throw const FormatException('LAN transfer exceeds 150 MiB');
          }
          sink.add(chunk);
        }
      } finally {
        await sink.close();
      }
      return target;
    } catch (_) {
      if (target != null && await target.exists()) await target.delete();
      rethrow;
    } finally {
      client.close(force: true);
    }
  }
}
