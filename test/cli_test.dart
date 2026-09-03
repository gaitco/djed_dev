import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:djed_dev/djed_dev.dart';
import 'package:test/test.dart';

void main() {
  late Directory home;
  late DjedPaths paths;
  late FakePlatform platform;
  late StringBuffer out;
  late StringBuffer err;

  setUp(() {
    home = Directory.systemTemp.createTempSync('djed_cli');
    paths = DjedPaths(home);
    platform = FakePlatform();
    out = StringBuffer();
    err = StringBuffer();
  });
  tearDown(() => home.deleteSync(recursive: true));

  /// [environment] defaults to empty, not to the process environment:
  /// `runDjed` refuses to run under `sudo`, and without this every case
  /// in this file would silently depend on whoever ran `dart test` not
  /// having SUDO_USER set. `consoleUser` falls back to `id -un` when USER
  /// is absent, which is what `install` needs.
  Future<int> run(
    List<String> args, {
    String openssl = 'openssl',
    Map<String, String> environment = const {},
  }) => runDjed(
    args,
    platform: platform,
    paths: paths,
    out: out,
    err: err,
    daemonCommand: const ['/usr/local/bin/djed', 'daemon'],
    controlFactory: (_) async => null,
    openssl: openssl,
    environment: environment,
  );

  test(
    'install refuses while Herd or Valet holds 443 and names the fix',
    () async {
      platform.listenersResult = const [PortOwner(443, 5536, 'nginx-arm')];
      expect(await run(['install']), 1);
      expect(
        err.toString(),
        contains('Port 443 is used by nginx-arm (pid 5536)'),
      );
      expect(err.toString(), contains('herd stop'));
      expect(platform.calls, isEmpty);
    },
  );

  test('install runs every step in order', () async {
    expect(await run(['install']), 0, reason: err.toString());
    expect(platform.calls, [
      'trustCa ${paths.caCert.path}',
      'writeResolver test 53535',
      'installAgent',
      'startAgent',
    ]);
    expect(paths.config.existsSync(), isTrue);
    expect(paths.leafCert.existsSync(), isTrue);
    expect(out.toString(), contains('djed installed'));
  });

  test(
    'install fails cleanly when openssl is missing, no stack trace',
    () async {
      final code = await run(['install'], openssl: 'no-such-openssl-binary');
      expect(code, 1);
      expect(err.toString(), contains('OpenSSL'));
      expect(err.toString(), isNot(contains('#0')));
      expect(platform.calls, isEmpty);
    },
  );

  test('an openssl permissions failure does not advise installing it', () async {
    final denying = File(p.join(home.path, 'denying-ssl'))
      ..writeAsStringSync(
        '#!/bin/sh\necho "Could not open file: Permission denied" >&2\nexit 1\n',
      );
    await Process.run('/bin/chmod', ['700', denying.path]);
    await DjedConfig(openssl: denying.path).save(paths);
    expect(await run(['secure']), 1);
    expect(err.toString(), contains('Permission denied'));
    expect(err.toString(), isNot(contains('brew install')));
    expect(err.toString(), contains(paths.home.path));
  });

  test('every command refuses to run under sudo', () async {
    for (final command in [
      ['install'],
      ['uninstall'],
      ['secure'],
      ['start'],
      ['stop'],
      ['restart'],
    ]) {
      err.clear();
      final code = await run(
        command,
        environment: {'SUDO_USER': 'abdullah', 'USER': 'root'},
      );
      expect(code, 1, reason: command.first);
      expect(err.toString(), contains('without sudo'), reason: command.first);
      expect(platform.calls, isEmpty, reason: command.first);
    }
  });

  test('install refuses to run under sudo', () async {
    // sudo sets HOME=/var/root, so DjedPaths would put everything in
    // root's home while DJED_USER named the human: the daemon would
    // read a config the user could never see, and their `djed status`
    // would say "not running" forever.
    final code = await run(['install'], environment: {'SUDO_USER': 'abdullah'});
    expect(code, 1);
    expect(err.toString(), contains('without sudo'));
    expect(platform.calls, isEmpty);
  });

  test('install refuses a console user the system does not know', () async {
    final code = await run(
      ['install'],
      environment: {'USER': 'no-such-account-here'},
    );
    expect(code, 1);
    expect(err.toString(), contains('no-such-account-here'));
    expect(platform.calls, isEmpty);
  });

  test(
    'a permissions failure is not blamed on OpenSSL',
    () async {
      // A CA directory the user can no longer chmod (uchg reproduces the
      // EPERM without needing another owner) used to be reported as
      // "install OpenSSL", which fixes nothing.
      paths.ensureDirectories();
      paths.caKey.writeAsStringSync('');
      paths.caCert.writeAsStringSync('');
      await Process.run('chflags', ['uchg', paths.caKey.path]);
      final code = await run(['install']);
      await Process.run('chflags', ['nouchg', paths.caKey.path]);
      expect(code, 1);
      expect(err.toString(), contains(paths.caKey.path));
      expect(err.toString().toLowerCase(), isNot(contains('openssl')));
      expect(platform.calls, isEmpty);
    },
    skip: Platform.isMacOS ? false : 'requires macOS chflags',
  );

  test('park, forget, link, unlink and links edit the config', () async {
    final sites = Directory(p.join(home.path, 'Sites'))..createSync();
    final blog = Directory(p.join(sites.path, 'blog'))..createSync();
    File(p.join(blog.path, 'bin', 'server.dart')).createSync(recursive: true);
    expect(await run(['park', sites.path]), 0);
    expect((await DjedConfig.load(paths)).paths, [sites.path]);
    expect(await run(['link', 'notes', blog.path]), 0);
    expect((await DjedConfig.load(paths)).links, {'notes': blog.path});
    out.clear();
    expect(await run(['links']), 0);
    expect(out.toString(), contains('blog'));
    expect(out.toString(), contains('https://notes.test'));
    expect(await run(['unlink', 'notes']), 0);
    expect((await DjedConfig.load(paths)).links, isEmpty);
    expect(await run(['forget', sites.path]), 0);
    expect((await DjedConfig.load(paths)).paths, isEmpty);
  });

  test('install records the openssl it resolved in the config', () async {
    expect(await run(['install']), 0, reason: err.toString());
    // An absolute path, so the daemon does not fall back to launchd's own
    // PATH (where `openssl` is macOS's LibreSSL).
    expect((await DjedConfig.load(paths)).openssl, startsWith('/'));
  });

  test('secure uses the openssl named in the config', () async {
    await DjedConfig(openssl: '/nonexistent/openssl').save(paths);
    expect(await run(['secure']), 1);
    expect(err.toString(), contains('/nonexistent/openssl'));
    expect(err.toString(), contains('OpenSSL'));
  });

  test('link refuses a name that normalizes to nothing', () async {
    final dir = Directory(p.join(home.path, 'app'))..createSync();
    File(p.join(dir.path, 'bin', 'server.dart')).createSync(recursive: true);
    expect(await run(['link', '!!!', dir.path]), 1);
    expect(err.toString(), contains('1-63 characters'));
    expect((await DjedConfig.load(paths)).links, isEmpty);
    err.clear();
    expect(await run(['link', 'a' * 64, dir.path]), 1);
    expect((await DjedConfig.load(paths)).links, isEmpty);
  });

  test('link refuses a directory without bin/server.dart', () async {
    final dir = Directory(p.join(home.path, 'empty'))..createSync();
    expect(await run(['link', 'x', dir.path]), 1);
    expect(err.toString(), contains('bin/server.dart'));
  });

  test('status without a daemon says so', () async {
    expect(await run(['status']), 1);
    expect(out.toString(), contains('Daemon: not running'));
  });

  test(
    'open uses the platform and defaults to the current directory name',
    () async {
      expect(await run(['open', 'blog']), 0);
      expect(platform.calls, ['openUrl https://blog.test']);
    },
  );

  test('uninstall reverses install and --purge removes the home', () async {
    await run(['install']);
    platform.calls.clear();
    expect(await run(['uninstall', '--purge']), 0);
    expect(platform.calls, [
      'stopAgent',
      'uninstallAgent',
      'removeResolver test',
      'untrustCa ${paths.caCert.path}',
    ]);
    expect(home.existsSync(), isFalse);
    home.createSync();
  });

  test('unknown command prints usage and exits 64', () async {
    expect(await run(['bogus']), 64);
    expect(err.toString(), contains('Usage'));
  });
}
