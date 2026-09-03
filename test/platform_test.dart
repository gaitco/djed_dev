import 'dart:io';

import 'package:maat_djed/maat_djed.dart';
import 'package:test/test.dart';

const label = 'com.maat.djed';
const dest = '/Library/LaunchDaemons/$label.plist';
// A root process must not let PATH decide which binary it runs.
const sudo = '/usr/bin/sudo';
const launchctl = '/bin/launchctl';

/// A [MacOsPlatform] whose every subprocess is recorded instead of run.
/// `commands` is what a real install would type into a shell.
({MacOsPlatform platform, List<String> commands, List<String> announced})
recording({
  int Function(String exe, List<String> args)? exitCode,
  Map<String, String>? environment,
}) {
  final commands = <String>[];
  final announced = <String>[];
  final platform = MacOsPlatform(
    run: (exe, args) async {
      commands.add('$exe ${args.join(' ')}');
      if (exe.endsWith('/id')) return ProcessResult(0, 0, '501\n', '');
      return ProcessResult(0, exitCode?.call(exe, args) ?? 0, '', '');
    },
    announce: announced.add,
    environment: environment,
  );
  return (platform: platform, commands: commands, announced: announced);
}

void main() {
  test('launchd plist names the label, program and log', () {
    final paths = DjedPaths(Directory('/Users/x/.config/djed'));
    final plist = MacOsPlatform().launchdPlist(
      ['/usr/local/bin/djed', 'daemon'],
      paths,
      user: 'x',
    );
    expect(plist, contains('<string>com.maat.djed</string>'));
    expect(plist, contains('<string>/usr/local/bin/djed</string>'));
    expect(plist, contains('<string>daemon</string>'));
    expect(plist, contains('<key>RunAtLoad</key>'));
    expect(plist, contains('<key>KeepAlive</key>'));
    expect(plist, contains('/Users/x/.config/djed/logs/daemon.log'));
  });

  test('the daemon command runs the script, not just the Dart VM', () {
    final paths = DjedPaths(Directory('/Users/x/.config/djed'));
    final command = defaultDaemonCommand();
    final script = Platform.script.toFilePath();
    expect(command.first, Platform.resolvedExecutable);
    expect(command, containsAllInOrder([script, 'daemon']));
    final plist = MacOsPlatform().launchdPlist(command, paths, user: 'x');
    // Both as their own <string>: a plist of just [dart, daemon] makes
    // launchd respawn a VM that has no program to run every 10 seconds.
    expect(plist, contains('<string>$script</string>'));
    expect(plist, contains('<string>daemon</string>'));
  });

  test('a compiled binary is its own script', () {
    // `dart compile exe` reports the binary as executable AND script,
    // with no VM arguments. Repeating it would exec
    // `djed /usr/local/bin/djed daemon`, whose first argument is not
    // a command, so the daemon would never start.
    expect(
      daemonCommandFor(
        executable: '/usr/local/bin/djed',
        executableArguments: const [],
        script: '/usr/local/bin/djed',
      ),
      ['/usr/local/bin/djed', 'daemon'],
    );
  });

  test('a script run by the VM keeps the VM and its arguments', () {
    expect(
      daemonCommandFor(
        executable: '/dart-sdk/bin/dart',
        executableArguments: const ['--enable-vm-service'],
        script: '/repo/bin/djed.dart',
      ),
      [
        '/dart-sdk/bin/dart',
        '--enable-vm-service',
        '/repo/bin/djed.dart',
        'daemon',
      ],
    );
  });

  test('the plist is a LaunchDaemon: root, with the user in the env', () {
    final paths = DjedPaths(Directory('/Users/x/.config/djed'));
    final plist = MacOsPlatform().launchdPlist(
      ['/usr/local/bin/djed', 'daemon'],
      paths,
      user: 'abdullah',
      openssl: '/opt/homebrew/bin/openssl',
    );
    // No UserName: a LaunchDaemon runs as root, which is the only way to
    // bind 80 and 443. The console user travels in the environment so the
    // daemon can hand its files, and every app it spawns, back.
    expect(plist, isNot(contains('UserName')));
    expect(
      plist,
      contains('<key>DJED_HOME</key><string>/Users/x/.config/djed</string>'),
    );
    expect(plist, contains('<key>DJED_USER</key><string>abdullah</string>'));
    expect(
      plist,
      contains(
        '<key>DJED_OPENSSL</key><string>/opt/homebrew/bin/openssl</string>',
      ),
    );
  });

  test('launchd plist escapes XML-unsafe characters', () {
    final paths = DjedPaths(Directory('/Users/AT&T/.config/djed'));
    final plist = MacOsPlatform().launchdPlist(
      ['/usr/local/bin/djed', 'daemon'],
      paths,
      user: 'AT&T',
    );
    expect(plist, contains('AT&amp;T'));
    expect(plist, isNot(contains('AT&T')));
  });

  test('listeners parses lsof output', () async {
    final platform = MacOsPlatform(
      run: (exe, args) async => ProcessResult(
        0,
        0,
        'COMMAND   PID USER   FD   TYPE DEVICE SIZE/OFF NODE NAME\n'
            'nginx-arm 5536 abdullah 6u IPv4 0x1 0t0 TCP 127.0.0.1:80 (LISTEN)\n'
            'nginx-arm 5536 abdullah 7u IPv4 0x2 0t0 TCP 127.0.0.1:443 (LISTEN)\n',
        '',
      ),
    );
    final owners = await platform.listeners([80, 443]);
    expect(owners.map((o) => (o.port, o.pid, o.command)), [
      (80, 5536, 'nginx-arm'),
      (443, 5536, 'nginx-arm'),
    ]);
  });

  test('privileged steps announce themselves and shell out with sudo', () async {
    final r = recording();
    await r.platform.writeResolver('test', 53535);
    await r.platform.trustCa(File('/tmp/ca.pem'));
    expect(r.commands.first, startsWith('$sudo '));
    expect(r.commands.first, contains('/etc/resolver/test'));
    expect(
      r.commands.last,
      contains(
        'security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain /tmp/ca.pem',
      ),
    );
    expect(r.announced.length, 2);
  });

  test('installAgent installs the plist as root and bootstraps it', () async {
    final r = recording();
    await r.platform.installAgent('<plist/>');
    expect(
      r.commands.first,
      matches(
        RegExp('^$sudo /usr/bin/install -m 0644 -o root -g wheel \\S+ $dest\$'),
      ),
    );
    // Bootstrapping over a job that is already loaded fails; boot it out
    // first so re-running `install` is not an error.
    expect(
      r.commands,
      containsAllInOrder([
        '$sudo $launchctl bootout system/$label',
        '$sudo $launchctl bootstrap system $dest',
      ]),
    );
    expect(r.announced, isNotEmpty);
  });

  test('install and uninstall clear the old per-user LaunchAgent', () async {
    // Anyone who ran the previous version still has a LaunchAgent loaded
    // in their gui domain, crash-looping against port 80 every ten
    // seconds and writing into the same log as the root daemon.
    for (final act in <Future<void> Function(MacOsPlatform)>[
      (p) => p.installAgent('<plist/>'),
      (p) => p.uninstallAgent(),
    ]) {
      final r = recording(environment: {'HOME': '/tmp/fake-home'});
      await act(r.platform);
      expect(
        r.commands,
        containsAllInOrder([
          '/usr/bin/id -u',
          '$launchctl bootout gui/501/$label',
          // The *injected* HOME: reverting to Platform.environment would
          // fail here. Removed through the runner, never with dart:io, so
          // a test cannot reach into a real home directory.
          '/bin/rm -f /tmp/fake-home/Library/LaunchAgents/$label.plist',
        ]),
      );
    }
  });

  test('a bootstrap that races launchd is retried once', () async {
    // `bootout` returns before launchd has finished tearing the job down,
    // so the bootstrap right behind it can lose the race - with the new
    // plist installed and the old daemon gone, which is the worst place
    // to give up.
    var bootstraps = 0;
    final r = recording(
      exitCode: (exe, args) =>
          args.contains('bootstrap') && bootstraps++ == 0 ? 5 : 0,
    );
    await r.platform.installAgent('<plist/>');
    expect(bootstraps, 2);
    expect(r.commands.last, '$sudo $launchctl bootstrap system $dest');
  });

  test('installAgent over an already-loaded job succeeds', () async {
    // bootout exits 3 ("No such process") when nothing is loaded, and
    // 0 when it unloaded the running job: neither is a failure.
    for (final code in [0, 3]) {
      final r = recording(
        exitCode: (exe, args) => args.contains('bootout') ? code : 0,
      );
      await r.platform.installAgent('<plist/>');
      expect(r.commands.last, '$sudo $launchctl bootstrap system $dest');
    }
  });

  test('uninstallAgent boots the job out and removes the plist', () async {
    final r = recording(
      exitCode: (exe, args) => args.contains('bootout') ? 3 : 0,
    );
    await r.platform.uninstallAgent();
    expect(
      r.commands,
      containsAllInOrder([
        '$sudo $launchctl bootout system/$label',
        '$sudo /bin/rm -f $dest',
      ]),
    );
  });

  test('startAgent kickstarts the system job', () async {
    final r = recording();
    await r.platform.startAgent();
    expect(r.commands, ['$sudo $launchctl kickstart -k system/$label']);
  });

  test('stopAgent boots the job out instead of restarting it', () async {
    // `launchctl stop` on a KeepAlive job means "restart it".
    final r = recording();
    await r.platform.stopAgent();
    expect(r.commands, ['$sudo $launchctl bootout system/$label']);
  });

  test('a booted-out job is bootstrapped again before kickstart', () async {
    var kicks = 0;
    final r = recording(
      exitCode: (exe, args) {
        // kickstart fails the first time: nothing is loaded.
        if (args.contains('kickstart')) return kicks++ == 0 ? 3 : 0;
        return 0;
      },
    );
    await r.platform.startAgent();
    expect(r.commands, [
      '$sudo $launchctl kickstart -k system/$label',
      '$sudo $launchctl bootstrap system $dest',
      '$sudo $launchctl kickstart -k system/$label',
    ]);
  });

  test('agentRunning asks launchctl about the system domain', () async {
    final platform = MacOsPlatform(
      run: (exe, args) async => ProcessResult(0, 0, 'state = running', ''),
      announce: (_) {},
    );
    expect(await platform.agentRunning(), isTrue);
    final r = recording();
    expect(await r.platform.agentRunning(), isFalse);
    expect(r.commands, ['$sudo $launchctl print system/$label']);
  });

  test('a failing launchctl throws instead of reporting success', () async {
    final platform = MacOsPlatform(
      run: (exe, args) async =>
          ProcessResult(0, 1, '', 'Bootstrap failed: 5: I/O error'),
      announce: (_) {},
    );
    await expectLater(
      platform.startAgent(),
      throwsA(
        isA<ProcessException>().having(
          (e) => e.message,
          'message',
          contains('Bootstrap failed'),
        ),
      ),
    );
    // bootout on a label that was never loaded (exit 3) is the wanted
    // outcome, not a failure.
    final missing = MacOsPlatform(
      run: (exe, args) async =>
          ProcessResult(0, 3, '', 'Boot-out failed: 3: No such process'),
      announce: (_) {},
    );
    await missing.stopAgent();
  });

  test('fake platform records calls', () async {
    final fake = FakePlatform();
    await fake.writeResolver('test', 53535);
    await fake.startAgent();
    expect(fake.calls, ['writeResolver test 53535', 'startAgent']);
    expect(await fake.agentRunning(), isFalse);
    fake.agentRunningResult = true;
    expect(await fake.agentRunning(), isTrue);
  });
}
