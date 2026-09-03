import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:djed_dev/djed_dev.dart';
import 'package:test/test.dart';

final fixture = p.absolute('test', 'fixtures', 'fake_app');

void main() {
  late Directory home;
  late AppRunner runner;

  setUp(() {
    home = Directory.systemTemp.createTempSync('djed_runner');
    Directory(p.join(home.path, 'logs')).createSync();
    runner = AppRunner(
      tld: 'test',
      logs: Directory(p.join(home.path, 'logs')),
      idle: const Duration(seconds: 1),
      startTimeout: const Duration(seconds: 20),
      pollInterval: const Duration(milliseconds: 100),
    );
  });
  tearDown(() async {
    await runner.stopAll();
    home.deleteSync(recursive: true);
  });

  test('a root daemon spawns apps through sudo as the console user', () {
    // Asserted as a shape, not by spawning: the test process is not root,
    // and `sudo` in a test suite would prompt.
    final logs = Directory(p.join(home.path, 'logs'));
    final dropped = AppRunner(
      tld: 'test',
      logs: logs,
      runAsUser: 'abdullah',
      runningAsRoot: true,
    );
    expect(dropped.spawnCommand(), [
      '/usr/bin/sudo',
      '-u',
      'abdullah',
      '-H',
      '--',
      Platform.resolvedExecutable,
      'run',
      'bin/server.dart',
    ]);
    // sudo's env_reset drops APP_PORT on the way through, so it travels
    // as sudo's own VAR=value option instead of being inherited - before
    // the `--`, since sudo(1) lists VAR=value among the options.
    expect(
      dropped.spawnCommand({'APP_PORT': '4242'}),
      containsAllInOrder([
        '-H',
        'APP_PORT=4242',
        '--',
        Platform.resolvedExecutable,
      ]),
    );
    // launchd hands the daemon a bare /usr/bin:/bin:/usr/sbin:/sbin PATH,
    // where `dart` does not resolve at all.
    expect(dropped.command.first, Platform.resolvedExecutable);
    expect(dropped.command.first, isNot('dart'));
    // Not root: the command is spawned exactly as it always was.
    final plain = AppRunner(
      tld: 'test',
      logs: logs,
      runAsUser: 'abdullah',
      runningAsRoot: false,
    );
    expect(plain.spawnCommand({'APP_PORT': '1'}), plain.command);
    expect(
      AppRunner(tld: 'test', logs: logs, runningAsRoot: true).spawnCommand(),
      isNot(contains('sudo')),
    );
  });

  test('allocatePort returns an unprivileged port', () async {
    final port = await allocatePort();
    expect(port, inInclusiveRange(1025, 65535));
  });

  test(
    'ensureRunning starts the app once and serves through the port',
    () async {
      final site = Site('fake', fixture);
      final port = await runner.ensureRunning(site);
      final again = await runner.ensureRunning(site);
      expect(again, port);
      final client = HttpClient();
      final response = await (await client.getUrl(
        Uri.parse('http://127.0.0.1:$port/hi'),
      )).close();
      expect(response.statusCode, 200);
      client.close();
      final status = runner.status().single;
      expect(status.name, 'fake');
      expect(status.port, port);
      expect(status.state, 'running');
      expect(runner.logTail('fake'), contains('url=https://fake.test'));
    },
  );

  test(
    'the port and url reach spawnCommand, not just the environment',
    () async {
      // Wrapped in sudo they can only travel as VAR=value arguments, and
      // the only place that is decided is this call.
      final logs = Directory(p.join(home.path, 'logs'));
      final commands = <String>[];
      final spy = _SpyRunner(
        tld: 'test',
        logs: logs,
        pollInterval: const Duration(milliseconds: 100),
        startTimeout: const Duration(seconds: 20),
        run: (exe, args) async {
          commands.add('$exe ${args.join(' ')}');
          return ProcessResult(0, 0, '', '');
        },
      );
      addTearDown(spy.stopAll);
      final port = await spy.ensureRunning(Site('fake', fixture));
      expect(spy.seen, {
        'APP_HOST': '127.0.0.1',
        'APP_PORT': '$port',
        'APP_URL': 'https://fake.test',
      });
      // The sink belongs to the root parent, not to the app that dropped
      // privileges, so without this the log is created root-owned on a
      // site's first request - hours after the daemon's own chown pass.
      expect(commands, [
        '/usr/sbin/chown abdullah ${p.join(logs.path, 'fake.log')}',
      ]);
    },
  );

  test('concurrent callers share one start', () async {
    final site = Site('fake', fixture);
    final ports = await Future.wait([
      runner.ensureRunning(site),
      runner.ensureRunning(site),
    ]);
    expect(ports.first, ports.last);
    expect(runner.status().length, 1);
  });

  test('a process that exits is StartFailed with the log tail', () async {
    final failing = AppRunner(
      tld: 'test',
      logs: Directory(p.join(home.path, 'logs')),
      environment: {'FAIL': '1'},
      pollInterval: const Duration(milliseconds: 100),
    );
    await expectLater(
      failing.ensureRunning(Site('fake', fixture)),
      throwsA(
        isA<StartFailed>()
            .having((e) => e.exitCode, 'exitCode', 1)
            .having((e) => e.message, 'message', contains('refusing to start')),
      ),
    );
    expect(failing.status(), isEmpty);
  });

  test('a process that never listens is StartTimeout', () async {
    final slow = AppRunner(
      tld: 'test',
      logs: Directory(p.join(home.path, 'logs')),
      environment: {'SLOW': '1'},
      startTimeout: const Duration(milliseconds: 700),
      pollInterval: const Duration(milliseconds: 100),
    );
    await expectLater(
      slow.ensureRunning(Site('fake', fixture)),
      throwsA(isA<StartTimeout>()),
    );
    expect(slow.status(), isEmpty, reason: 'killed after timeout');
  });

  test('stopIdle stops apps idle longer than the limit', () async {
    final site = Site('fake', fixture);
    await runner.ensureRunning(site);
    await runner.stopIdle(DateTime.now().add(const Duration(seconds: 2)));
    expect(runner.status(), isEmpty);
    await runner.ensureRunning(site);
    runner.touch('fake');
    await runner.stopIdle(
      DateTime.now().add(const Duration(milliseconds: 500)),
    );
    expect(runner.status().length, 1);
  });

  test(
    'restart yields a new pid on a fresh port; markStopped forgets',
    () async {
      final site = Site('fake', fixture);
      final port = await runner.ensureRunning(site);
      final pid = runner.status().single.pid;
      await runner.restart(site);
      final status = runner.status().single;
      expect(status.pid, isNot(pid));
      expect(status.port, isNot(port));
      runner.markStopped('fake');
      expect(runner.status(), isEmpty);
    },
  );

  test('an open tunnel holds the app through the idle sweep', () async {
    final site = Site('fake', fixture);
    await runner.ensureRunning(site);
    runner.openTunnel('fake');
    await runner.stopIdle(DateTime.now().add(const Duration(hours: 1)));
    expect(runner.status().length, 1, reason: 'a live socket is not idle');
    runner.closeTunnel('fake');
    await runner.stopIdle(DateTime.now().add(const Duration(hours: 1)));
    expect(runner.status(), isEmpty);
  });

  test('stopping an app that ignores SIGTERM does not crash', () async {
    // The kill-grace path used to close the log sink while the exit
    // listener was still pending: SIGKILL landing afterwards wrote into a
    // closed IOSink and the unhandled StreamSink error killed the daemon.
    final stubborn = AppRunner(
      tld: 'test',
      logs: Directory(p.join(home.path, 'logs')),
      environment: {'IGNORE_SIGTERM': '1'},
      pollInterval: const Duration(milliseconds: 100),
      killGrace: const Duration(milliseconds: 300),
    );
    final site = Site('stubborn', fixture);
    await stubborn.ensureRunning(site);
    final pid = stubborn.status().single.pid;
    await stubborn.stop('stubborn');
    expect(stubborn.status(), isEmpty);
    expect((await Process.run('kill', ['-0', '$pid'])).exitCode, isNot(0));
    // Give any late write from the dead process a chance to surface as an
    // unhandled error before the test ends.
    await Future<void>.delayed(const Duration(milliseconds: 300));
  });

  test('markStopped terminates a still-running process', () async {
    final site = Site('fake', fixture);
    await runner.ensureRunning(site);
    final pid = runner.status().single.pid;
    runner.markStopped('fake');
    expect(runner.status(), isEmpty);
    final deadline = DateTime.now().add(const Duration(seconds: 6));
    var gone = false;
    while (DateTime.now().isBefore(deadline)) {
      final result = await Process.run('kill', ['-0', '$pid']);
      if (result.exitCode != 0) {
        gone = true;
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(gone, isTrue, reason: 'process $pid should have been terminated');
  });

  test('stop terminates a running process and clears its status', () async {
    final site = Site('fake', fixture);
    await runner.ensureRunning(site);
    final pid = runner.status().single.pid;
    await runner.stop('fake');
    expect(runner.status(), isEmpty);
    final deadline = DateTime.now().add(const Duration(seconds: 6));
    var gone = false;
    while (DateTime.now().isBefore(deadline)) {
      final result = await Process.run('kill', ['-0', '$pid']);
      if (result.exitCode != 0) {
        gone = true;
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(gone, isTrue, reason: 'process $pid should have been terminated');
  });
}

/// Records what `_start` hands to [spawnCommand]; not root, so the
/// command it returns is the plain one and the app really starts.
class _SpyRunner extends AppRunner {
  _SpyRunner({
    required super.tld,
    required super.logs,
    super.pollInterval,
    super.startTimeout,
    super.run,
  }) : super(runAsUser: 'abdullah', runningAsRoot: true);

  Map<String, String>? seen;

  /// Records what `_start` passes, and returns the *unwrapped* command:
  /// the runner believes it is root, so everything else takes the
  /// privileged path, but the test must not actually spawn `sudo`.
  @override
  List<String> spawnCommand([Map<String, String> env = const {}]) {
    seen = env;
    return command;
  }
}
