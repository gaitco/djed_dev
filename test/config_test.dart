import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:maat_djed/maat_djed.dart';
import 'package:test/test.dart';

void main() {
  late Directory home;
  late DjedPaths paths;

  setUp(() {
    home = Directory.systemTemp.createTempSync('djed_config');
    paths = DjedPaths(home);
  });
  tearDown(() => home.deleteSync(recursive: true));

  test('defaults match the spec', () {
    final c = DjedConfig();
    expect(c.tld, 'test');
    expect(c.idleMinutes, 15);
    expect(c.dnsPort, 53535);
    expect(c.httpPort, 80);
    expect(c.httpsPort, 443);
    expect(c.startTimeoutSeconds, 60);
    expect(c.paths, isEmpty);
    expect(c.links, isEmpty);
    expect(c.url('blog'), 'https://blog.test');
  });

  test('load returns defaults when no file exists, save round-trips', () async {
    final loaded = await DjedConfig.load(paths);
    expect(loaded.tld, 'test');
    final changed = loaded.copyWith(
      paths: ['/tmp/sites'],
      links: {'blog': '/tmp/blog'},
      idleMinutes: 3,
    );
    await changed.save(paths);
    expect(paths.config.existsSync(), isTrue);
    final again = await DjedConfig.load(paths);
    expect(again.paths, ['/tmp/sites']);
    expect(again.links, {'blog': '/tmp/blog'});
    expect(again.idleMinutes, 3);
    expect(again.httpsPort, 443);
  });

  test('paths derive from home and DJED_HOME is honoured', () {
    expect(paths.config.path, p.join(home.path, 'config.json'));
    expect(paths.caCert.path, p.join(home.path, 'ca', 'ca.pem'));
    expect(paths.leafKey.path, p.join(home.path, 'certs', 'test.key'));
    expect(paths.siteLog('blog').path, p.join(home.path, 'logs', 'blog.log'));
    expect(paths.socket.path, p.join(home.path, 'daemon.sock'));
    final resolved = DjedPaths.resolve({'DJED_HOME': home.path});
    expect(resolved.home.path, home.path);
    final fallback = DjedPaths.resolve({'HOME': '/Users/x'});
    expect(fallback.home.path, '/Users/x/.config/djed');
  });

  test('a corrupt config file is a clear error', () async {
    paths.config.writeAsStringSync('{not json');
    expect(() => DjedConfig.load(paths), throwsA(isA<FormatException>()));
  });

  test('an invalid tld is rejected', () {
    expect(() => DjedConfig(tld: 'bad tld'), throwsA(isA<FormatException>()));
    expect(() => DjedConfig(tld: 'a;b'), throwsA(isA<FormatException>()));
  });

  test('the dart binary round-trips and defaults away from djed', () {
    // The regression: `dart compile exe` makes Platform.resolvedExecutable
    // the `djed` binary itself, and `djed run bin/server.dart` exits
    // 64 before the app ever listens. Whatever the default resolves to, it
    // must be a Dart VM.
    expect(defaultDartExecutable(), anyOf('dart', endsWith('/dart')));
    expect(DjedConfig().dart, isNot(endsWith('/djed')));
    final pinned = DjedConfig(dart: '/dart-sdk/bin/dart');
    expect(pinned.toJson()['dart'], '/dart-sdk/bin/dart');
    expect(DjedConfig.fromJson(pinned.toJson()).dart, '/dart-sdk/bin/dart');
    expect(appCommandFor(pinned.dart), [
      '/dart-sdk/bin/dart',
      'run',
      'bin/server.dart',
    ]);
  });
}
