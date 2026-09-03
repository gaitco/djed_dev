import 'dart:async';
import 'dart:io';

import 'package:djed_dev/djed_dev.dart';
import 'package:test/test.dart';

void main() {
  late Directory home;
  late DjedPaths paths;

  setUp(() {
    home = Directory.systemTemp.createTempSync('djed_control');
    paths = DjedPaths(home)..ensureDirectories();
  });
  tearDown(() => home.deleteSync(recursive: true));

  test('send times out when the daemon accepts but never replies', () async {
    final server = await ServerSocket.bind(
      InternetAddress(paths.socket.path, type: InternetAddressType.unix),
      0,
    );
    final subscription = server.listen((socket) {
      // Accepts the connection and never writes a reply.
    });
    addTearDown(() async {
      await subscription.cancel();
      await server.close();
    });

    final client = ControlClient(paths.socket);
    final stopwatch = Stopwatch()..start();
    await expectLater(
      client.send({
        'cmd': 'status',
      }, timeout: const Duration(milliseconds: 300)),
      throwsA(isA<TimeoutException>()),
    );
    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 1)));
  });
}
