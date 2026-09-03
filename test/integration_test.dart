import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:maat_djed/maat_djed.dart';
import 'package:test/test.dart';

final fixture = p.absolute('test', 'fixtures', 'fake_app');

void main() {
  late Directory home;
  late DjedPaths paths;
  late Daemon daemon;
  late HttpClient client;
  late Directory watched;
  late int dnsPort;
  late int httpPort;
  late int httpsPort;

  /// A site whose source the test can break, to prove a failing restart
  /// does not take the daemon with it. Its own package, not the shared
  /// fixture, because the test overwrites its `bin/server.dart`.
  void writeWatchedApp({required bool working}) {
    File(
      p.join(watched.path, 'pubspec.yaml'),
    ).writeAsStringSync('name: watched_app\nenvironment:\n  sdk: ^3.12.0\n');
    File(p.join(watched.path, 'bin', 'server.dart'))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(
        working
            ? "import 'dart:io';\n"
                  'Future<void> main() async {\n'
                  "  final s = await HttpServer.bind('127.0.0.1',\n"
                  "      int.parse(Platform.environment['APP_PORT']!));\n"
                  '  await for (final r in s) {\n'
                  "    r.response.write('{}');\n"
                  '    await r.response.close();\n'
                  '  }\n'
                  '}\n'
            : "import 'dart:io';\nvoid main() => exit(1);\n",
      );
  }

  setUp(() async {
    final httpReservation = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final httpsReservation = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final dnsReservation = await RawDatagramSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    httpPort = httpReservation.port;
    httpsPort = httpsReservation.port;
    dnsPort = dnsReservation.port;
    home = Directory.systemTemp.createTempSync('djed_it');
    paths = DjedPaths(home)..ensureDirectories();
    watched = Directory(p.join(home.path, 'watched'))
      ..createSync(recursive: true);
    Directory(p.join(watched.path, 'lib')).createSync();
    writeWatchedApp(working: true);
    final certs = Certificates(paths);
    await certs.ensureCa();
    final config = DjedConfig(
      links: {'fake': fixture, 'other': fixture, 'watched': watched.path},
      idleMinutes: 1,
      dnsPort: dnsPort,
      httpPort: httpPort,
      httpsPort: httpsPort,
    );
    await config.save(paths);
    await httpReservation.close();
    await httpsReservation.close();
    dnsReservation.close();
    // certificates: certs, not securityContext - the daemon now generates
    // and maintains the leaf itself (per-site SANs, regenerated and
    // rebound whenever the site list changes; see certificates.dart).
    daemon = Daemon(paths: paths, config: config, certificates: certs);
    await daemon.start();
    final trust = SecurityContext()..setTrustedCertificates(paths.caCert.path);
    client = HttpClient(context: trust);
    // Redirect *.test to loopback without touching system DNS. A plain
    // Socket.startConnect() is not enough for https: HttpClient only
    // auto-upgrades to TLS for a *default* connection; a custom
    // connectionFactory is handed the raw socket as-is and must secure it
    // itself (see HttpClient docs/ConnectionTask.fromSocket).
    //
    // Unlike the single global `*.test` wildcard this daemon used to rely
    // on (which never passes strict RFC 6125 hostname verification for a
    // single-label tld - confirmed via curl and a raw SecureSocket
    // handshake), the leaf now lists every site by name, so verifying
    // strictly against the actual virtual hostname (`uri.host`, e.g.
    // `fake.test`) is exactly what should succeed.
    client.connectionFactory = (uri, proxyHost, proxyPort) async {
      final socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        uri.port,
      );
      if (uri.scheme != 'https') {
        return ConnectionTask.fromSocket(Future.value(socket), socket.destroy);
      }
      final secure = SecureSocket.secure(
        socket,
        host: uri.host,
        context: trust,
      );
      return ConnectionTask.fromSocket(secure, socket.destroy);
    };
  });
  tearDown(() async {
    client.close(force: true);
    await daemon.stop();
    home.deleteSync(recursive: true);
  });

  Future<Map<String, Object?>> fetch(String url) async {
    final response = await (await client.getUrl(Uri.parse(url))).close();
    expect(response.statusCode, 200);
    return jsonDecode(await utf8.decoder.bind(response).join())
        as Map<String, Object?>;
  }

  test(
    'https and http requests reach the app, DNS answers, status reports',
    () async {
      final https = await fetch('https://fake.test:$httpsPort/hello');
      expect(https['forwardedProto'], 'https');
      expect(https['host'], 'fake.test:$httpsPort');
      final http = await fetch('http://other.test:$httpPort/');
      expect(http['forwardedProto'], 'http');

      // Read the reply inside the listener itself: `.where(...).first` would
      // cancel the subscription on match, and that cancellation discards the
      // datagram buffered by RawDatagramSocket before `receive()` gets a
      // chance to read it. See test/dns_responder_test.dart.
      final dns = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      final replyCompleter = Completer<Uint8List>();
      final subscription = dns.listen((event) {
        if (event != RawSocketEvent.read) return;
        final datagram = dns.receive();
        if (datagram != null && !replyCompleter.isCompleted) {
          replyCompleter.complete(datagram.data);
        }
      });
      dns.send(
        Uint8List.fromList([
          0,
          1,
          1,
          0,
          0,
          1,
          0,
          0,
          0,
          0,
          0,
          0,
          4,
          ...'fake'.codeUnits,
          4,
          ...'test'.codeUnits,
          0,
          0,
          1,
          0,
          1,
        ]),
        InternetAddress.loopbackIPv4,
        dnsPort,
      );
      final reply = await replyCompleter.future.timeout(
        const Duration(seconds: 2),
      );
      await subscription.cancel();
      dns.close();
      expect(reply.sublist(reply.length - 4), [127, 0, 0, 1]);

      final status = await ControlClient(paths.socket).send({'cmd': 'status'});
      expect(status['pid'], pid);
      expect(
        (status['apps'] as List).map((a) => (a as Map)['name']),
        containsAll(['fake', 'other']),
      );
      expect(status['httpsPort'], httpsPort);
      expect(paths.pidFile.readAsStringSync().trim(), '$pid');
    },
  );

  test(
    'control commands restart and stop sites, reload picks up config',
    () async {
      final first = await fetch('https://fake.test:$httpsPort/');
      await ControlClient(
        paths.socket,
      ).send({'cmd': 'restart', 'site': 'fake'});
      final second = await fetch('https://fake.test:$httpsPort/');
      expect(second['pid'], isNot(first['pid']));

      final config = (await DjedConfig.load(
        paths,
      )).copyWith(links: {'renamed': fixture});
      await config.save(paths);
      await ControlClient(paths.socket).send({'cmd': 'reload'});
      // Plain HTTP, not HTTPS: after reload the leaf no longer carries a
      // `fake.test` SAN at all (only 'renamed' is registered now), so a
      // strictly-verified HTTPS client can't even complete a handshake for
      // that name any more - the interesting assertion (the site is really
      // gone) is the routing check below, over a scheme with no
      // certificate to be strict about.
      final response = await (await client.getUrl(
        Uri.parse('http://fake.test:$httpPort/'),
      )).close();
      expect(response.statusCode, 404);
      expect(
        (await fetch('https://renamed.test:$httpsPort/'))['host'],
        'renamed.test:$httpsPort',
      );
      final status = await ControlClient(paths.socket).send({'cmd': 'status'});
      expect((status['sites'] as List).map((s) => (s as Map)['name']), [
        'renamed',
      ]);
      // reload() must stop apps for sites that disappeared from the
      // registry on its own - no explicit stop-site call here.
      expect(
        (status['apps'] as List).map((a) => (a as Map)['name']),
        isNot(contains('fake')),
      );
    },
  );

  test(
    'stop-site stops the running app; a later fetch starts it again',
    () async {
      await fetch('https://fake.test:$httpsPort/');
      await ControlClient(
        paths.socket,
      ).send({'cmd': 'stop-site', 'site': 'fake'});
      final status = await ControlClient(paths.socket).send({'cmd': 'status'});
      expect(
        (status['apps'] as List).map((a) => (a as Map)['name']),
        isNot(contains('fake')),
      );
      expect(
        (await fetch('https://fake.test:$httpsPort/'))['host'],
        'fake.test:$httpsPort',
      );
    },
  );

  test(
    'a site added by reload is served over HTTPS after the rebind',
    () async {
      final config = (await DjedConfig.load(
        paths,
      )).copyWith(links: {'fake': fixture, 'other': fixture, 'added': fixture});
      await config.save(paths);
      await ControlClient(paths.socket).send({'cmd': 'reload'});
      expect(
        (await fetch('https://added.test:$httpsPort/'))['host'],
        'added.test:$httpsPort',
      );
      final status = await ControlClient(paths.socket).send({'cmd': 'status'});
      expect(
        (status['sites'] as List).map((s) => (s as Map)['name']),
        containsAll(['fake', 'other', 'added']),
      );
    },
  );

  test('a second daemon refuses to start while the pid file is live', () async {
    final another = Daemon(paths: paths, config: await DjedConfig.load(paths));
    expect(() => another.start(), throwsA(isA<StateError>()));
    // start() never got past the pid guard, so nothing it would normally
    // tear down was ever initialised; stop() must be a clean no-op rather
    // than a LateInitializationError.
    await another.stop();
  });

  test(
    'a save that stops the app compiling leaves the daemon standing',
    () async {
      await fetch('http://watched.test:$httpPort/');

      // Break the app, then touch a watched file so the change watcher
      // fires. The restart it schedules now throws StartFailed; unhandled,
      // that error left the root zone and killed the daemon, orphaning
      // every other app, on every save that did not compile.
      writeWatchedApp(working: false);
      File(p.join(watched.path, 'lib', 'app.dart')).writeAsStringSync('// x');
      await Future<void>.delayed(const Duration(seconds: 3));

      final status = await ControlClient(paths.socket).send({'cmd': 'status'});
      expect(status['pid'], pid, reason: 'the daemon is still answering');
      final response = await (await client.getUrl(
        Uri.parse('http://watched.test:$httpPort/'),
      )).close();
      expect(response.statusCode, 502);
      await response.drain<void>();
      // ...and the sites it was already serving are untouched.
      expect(
        (await fetch('https://fake.test:$httpsPort/'))['host'],
        'fake.test:$httpsPort',
      );
    },
    timeout: const Timeout(Duration(seconds: 120)),
  );

  test('log rotation keeps one backup', () async {
    final file = File(p.join(home.path, 'big.log'))
      ..writeAsBytesSync(List.filled(11, 65));
    await rotateLog(file, maxBytes: 10);
    expect(file.existsSync(), isFalse);
    expect(File('${file.path}.1').existsSync(), isTrue);
  });
}
