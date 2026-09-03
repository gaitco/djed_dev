import 'dart:io';

import 'package:maat_djed/maat_djed.dart';
import 'package:test/test.dart';

/// The daemon's privileged behaviour, driven without being root: the
/// process runner is injected, so `chown` and `chmod` are recorded rather
/// than run.
void main() {
  late Directory home;
  late DjedPaths paths;
  late List<String> commands;

  setUp(() {
    home = Directory.systemTemp.createTempSync('djed_root');
    paths = DjedPaths(home);
    commands = <String>[];
  });
  tearDown(() => home.deleteSync(recursive: true));

  Daemon build({
    required bool root,
    String? user = 'abdullah',
    int httpPort = 18081,
    int httpsPort = 18444,
    int dnsPort = 15354,
  }) => Daemon(
    paths: paths,
    config: DjedConfig(
      dnsPort: dnsPort,
      httpPort: httpPort,
      httpsPort: httpsPort,
    ),
    runAsUser: user,
    runningAsRoot: root,
    log: (_) {},
    run: (exe, args) async {
      commands.add('$exe ${args.join(' ')}');
      return ProcessResult(0, 0, '', '');
    },
  );

  test('a root daemon hands its home and socket back to the user', () async {
    final daemon = build(root: true);
    await daemon.start();
    addTearDown(daemon.stop);
    final sock = paths.socket.path;
    expect(commands, [
      // Before anything else is written...
      '/usr/sbin/chown -R abdullah ${home.path}',
      // ...the socket root just bound is the user's, and only theirs.
      '/usr/sbin/chown abdullah $sock',
      '/bin/chmod 0600 $sock',
      // ...and again once the pid file and the regenerated certificate
      // exist, which root created after the first pass.
      '/usr/sbin/chown -R abdullah ${home.path}',
    ]);
    commands.clear();
    await daemon.reload();
    expect(commands, ['/usr/sbin/chown -R abdullah ${home.path}']);
  });

  test('a daemon that is not root changes no ownership', () async {
    final daemon = build(root: false);
    await daemon.start();
    addTearDown(daemon.stop);
    expect(commands, isEmpty);
  });

  test('a root daemon without DJED_USER refuses to start', () async {
    final daemon = build(root: true, user: null);
    await expectLater(
      daemon.start(),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('DJED_USER'),
        ),
      ),
    );
    // Nothing was bound, and no app can have been spawned as root.
    expect(paths.pidFile.existsSync(), isFalse);
  });

  test('a root daemon refuses a privileged port it did not choose', () async {
    // config.json belongs to the user; a root daemon that believed it
    // could be told to bind :22 would be a way to replace sshd.
    await expectLater(
      build(root: true, httpPort: 22).start(),
      throwsA(
        isA<StateError>().having((e) => e.message, 'message', contains('22')),
      ),
    );
    expect(paths.pidFile.existsSync(), isFalse);
    for (final bad in [
      build(root: true, httpsPort: 25),
      build(root: true, dnsPort: 53),
    ]) {
      await expectLater(bad.start(), throwsA(isA<StateError>()));
    }
  });

  test('reload cannot hand a root daemon a privileged port either', () async {
    // `djed link`, `park`, `forget` and `unlink` all reload, and a
    // reload that changes the site list rebinds HTTPS - straight from
    // config.json. Guarding only start() left that door open.
    final daemon = build(root: true);
    await daemon.start();
    addTearDown(daemon.stop);
    final before = daemon.httpPort;
    await DjedConfig(
      dnsPort: 15354,
      httpPort: 18081,
      httpsPort: 22,
    ).save(paths);
    await expectLater(
      daemon.reload(),
      throwsA(
        isA<StateError>().having((e) => e.message, 'message', contains('22')),
      ),
    );
    // Refused, and still serving what it was serving before.
    expect(daemon.httpPort, before);
    final client = HttpClient();
    addTearDown(client.close);
    final response = await (await client.getUrl(
      Uri.parse('http://127.0.0.1:$before/'),
    )).close();
    expect(response.statusCode, 404, reason: 'the old listener is alive');
    await response.drain<void>();
  });
}
