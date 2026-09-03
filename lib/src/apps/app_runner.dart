import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../config.dart';
import '../platform/platform.dart';
import '../sites.dart';
import 'port_allocator.dart';

class AppStatus {
  const AppStatus({
    required this.name,
    required this.port,
    required this.pid,
    required this.startedAt,
    required this.lastRequest,
    required this.state,
  });

  final String name;
  final int port;
  final int pid;
  final DateTime startedAt;
  final DateTime lastRequest;

  /// `starting` or `running`.
  final String state;

  Map<String, Object?> toJson() => {
    'name': name,
    'port': port,
    'pid': pid,
    'startedAt': startedAt.toIso8601String(),
    'lastRequest': lastRequest.toIso8601String(),
    'state': state,
  };
}

/// The process exited before it listened.
class StartFailed implements Exception {
  StartFailed(this.site, this.exitCode, this.logTail);
  final Site site;
  final int exitCode;
  final String logTail;
  String get message =>
      '${site.name} exited with code $exitCode before listening.\n$logTail';
  @override
  String toString() => 'StartFailed: $message';
}

/// The process is alive but never opened its port in time.
class StartTimeout implements Exception {
  StartTimeout(this.site, this.timeout, this.logTail);
  final Site site;
  final Duration timeout;
  final String logTail;
  String get message =>
      '${site.name} did not listen within ${timeout.inSeconds}s.\n$logTail';
  @override
  String toString() => 'StartTimeout: $message';
}

/// Writes to an app's log sink, tolerating a sink that has already been
/// closed. A killed process's exit and its last stdout still arrive after
/// `stop()` has closed the sink, and `IOSink.write` on a closed sink
/// throws `Bad state: StreamSink is closed` from inside a stream listener
/// — an unhandled async error that takes the whole daemon down.
void _write(IOSink sink, String data) {
  try {
    sink.write(data);
  } catch (_) {
    // The app is being torn down; losing its last log line is fine.
  }
}

void _writeln(IOSink sink, String data) => _write(sink, '$data\n');

class _App {
  _App(this.site, this.port, this.process, this.log);
  final Site site;
  final int port;
  final Process process;
  final IOSink log;
  final startedAt = DateTime.now();
  DateTime lastRequest = DateTime.now();
  bool ready = false;
  int? exitCode;
}

/// Dart exposes no `geteuid`, and the answer never changes within a
/// process, so it is asked for once, lazily, the first time anything
/// needs it.
///
/// An answer that is not a number is not "probably not root": it is no
/// answer, and guessing would silently run every application as root. It
/// throws instead.
final bool runningAsRootProcess = _euid() == 0;

int _euid() {
  final result = Process.runSync('/usr/bin/id', ['-u']);
  final uid = int.tryParse(result.stdout.toString().trim());
  if (uid == null) {
    throw StateError(
      'djed cannot tell what user it is running as: `/usr/bin/id -u` '
      'exited ${result.exitCode} saying "${result.stdout}${result.stderr}". '
      'Refusing to guess, because guessing wrong runs your applications '
      'as root.',
    );
  }
  return uid;
}

/// `dart run bin/server.dart` with `dart` spelled out. launchd hands the
/// daemon a bare `/usr/bin:/bin:/usr/sbin:/sbin` PATH, on which a bare
/// `dart` does not resolve at all, so [dartExecutable] is the absolute
/// path `install` pinned in `config.json`.
List<String> appCommandFor(String dartExecutable) => [
  dartExecutable,
  'run',
  'bin/server.dart',
];

/// The command for a daemon with no configuration to read — tests, and
/// the development `dart run bin/djed.dart daemon`.
List<String> defaultAppCommand() => appCommandFor(defaultDartExecutable());

/// Starts apps on demand, stops them when idle, restarts them on request.
class AppRunner {
  AppRunner({
    required this.tld,
    required this.logs,
    this.idle = const Duration(minutes: 15),
    this.startTimeout = const Duration(seconds: 60),
    this.pollInterval = const Duration(milliseconds: 250),
    List<String>? command,
    this.environment = const {},
    this.killGrace = const Duration(seconds: 5),
    this.runAsUser,
    bool? runningAsRoot,
    Runner? run,
  }) : command = command ?? defaultAppCommand(),
       runningAsRoot = runningAsRoot ?? runningAsRootProcess,
       _run = run ?? ((exe, args) => Process.run(exe, args));

  final String tld;
  final Directory logs;
  final Duration idle;
  final Duration startTimeout;
  final Duration pollInterval;
  final List<String> command;

  /// Extra environment for every app. Under `sudo` these become
  /// command-line `VAR=value` arguments, which `ps` shows to every user
  /// on the machine: never put a secret here.
  final Map<String, String> environment;
  final Duration killGrace;

  /// The console user an app must run as. The daemon itself is root — the
  /// only way to bind 80 and 443 — but the developer's project files,
  /// databases and caches must not become root's.
  final String? runAsUser;

  /// Both are injectable so the wrapped shape can be tested without being
  /// root, and so a daemon that is not root never wraps anything.
  final bool runningAsRoot;

  final Runner _run;

  /// What is actually spawned: the plain [command], or that command
  /// behind `sudo -u <user> -H` when a root daemon has to drop back.
  ///
  /// [env] is spelled out as `sudo`'s own `VAR=value` arguments rather
  /// than inherited, because `env_reset` — on by default in the sudoers
  /// macOS ships — builds the child's environment from a whitelist that
  /// `APP_PORT` is not on, and an app that never learns its port never
  /// answers. Unwrapped, the process environment carries it as before.
  List<String> spawnCommand([Map<String, String> env = const {}]) => _wrapped
      ? [
          '/usr/bin/sudo',
          '-u',
          runAsUser!,
          '-H',
          // sudo(1) lists VAR=value among the *options*, and `--` ends
          // the options: the assignments go before it, the command after.
          for (final e in env.entries) '${e.key}=${e.value}',
          '--',
          ...command,
        ]
      : command;

  bool get _wrapped => runAsUser != null && runningAsRoot;

  final _apps = <String, _App>{};
  final _starting = <String, Future<int>>{};

  /// Open WebSocket tunnels per site. A tunnel carries no requests once
  /// established, so without this the idle sweep kills the app out from
  /// under a live socket.
  final _tunnels = <String, int>{};

  /// The app's port, starting it first if needed. Concurrent callers for
  /// the same site await the same start.
  Future<int> ensureRunning(Site site) {
    final running = _apps[site.name];
    if (running != null && running.ready && running.exitCode == null) {
      running.lastRequest = DateTime.now();
      return Future.value(running.port);
    }
    return _starting.putIfAbsent(site.name, () async {
      try {
        return await _start(site);
      } finally {
        _starting.remove(site.name);
      }
    });
  }

  Future<int> _start(Site site) async {
    await stop(site.name);
    final port = await allocatePort();
    // createSync first: openWrite opens lazily, and the chown below has
    // to find a file. The sink belongs to this process — root, when
    // wrapping — so without the chown every site log is created
    // root-owned, on first request, long after the daemon's own pass.
    final logFile = File(p.join(logs.path, '${site.name}.log'))..createSync();
    final log = logFile.openWrite(mode: FileMode.append);
    if (_wrapped) {
      final result = await _run('/usr/sbin/chown', [runAsUser!, logFile.path]);
      if (result.exitCode != 0) {
        _writeln(log, 'chown ${logFile.path} failed: ${result.stderr}');
      }
    }
    _writeln(
      log,
      '[${DateTime.now().toIso8601String()}] starting on port $port',
    );
    final appEnv = {
      ...environment,
      'APP_HOST': '127.0.0.1',
      'APP_PORT': '$port',
      'APP_URL': 'https://${site.name}.$tld',
    };
    Process process;
    try {
      final argv = spawnCommand(appEnv);
      process = await Process.start(
        argv.first,
        argv.sublist(1),
        workingDirectory: site.path,
        environment: {...Platform.environment, ...appEnv},
      );
    } catch (e) {
      // The command or working directory doesn't exist: Process.start
      // throws synchronously instead of via exitCode. Report it the same
      // way as a process that exits immediately, so callers only need to
      // handle StartFailed/StartTimeout.
      _writeln(
        log,
        '[${DateTime.now().toIso8601String()}] failed to start: $e',
      );
      await log.close();
      throw StartFailed(site, -1, logTail(site.name));
    }
    final app = _App(site, port, process, log);
    _apps[site.name] = app;
    process.stdout.transform(utf8.decoder).listen((s) => _write(log, s));
    process.stderr.transform(utf8.decoder).listen((s) => _write(log, s));
    unawaited(
      process.exitCode.then((code) {
        app.exitCode = code;
        _writeln(
          log,
          '[${DateTime.now().toIso8601String()}] exited with $code',
        );
      }),
    );
    final deadline = DateTime.now().add(startTimeout);
    while (DateTime.now().isBefore(deadline)) {
      if (app.exitCode != null) {
        _apps.remove(site.name);
        await log.close();
        throw StartFailed(site, app.exitCode!, logTail(site.name));
      }
      if (await _accepts(port)) {
        app.ready = true;
        app.lastRequest = DateTime.now();
        return port;
      }
      await Future<void>.delayed(pollInterval);
    }
    await stop(site.name);
    throw StartTimeout(site, startTimeout, logTail(site.name));
  }

  Future<bool> _accepts(int port) async {
    try {
      final socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        port,
        timeout: const Duration(milliseconds: 200),
      );
      socket.destroy();
      return true;
    } on SocketException {
      return false;
    }
  }

  /// Records a request so the idle sweep leaves the app alone.
  void touch(String name) => _apps[name]?.lastRequest = DateTime.now();

  /// Marks a long-lived connection (a WebSocket tunnel) as open, so
  /// [stopIdle] leaves the app running for as long as it lasts.
  void openTunnel(String name) => _tunnels[name] = (_tunnels[name] ?? 0) + 1;

  void closeTunnel(String name) {
    final open = (_tunnels[name] ?? 0) - 1;
    if (open > 0) {
      _tunnels[name] = open;
    } else {
      _tunnels.remove(name);
    }
  }

  /// Forget an app the proxy found dead (connection refused). Terminates it
  /// first (SIGTERM, then SIGKILL after [killGrace]) in case it is actually
  /// still alive, so this never orphans a live process.
  void markStopped(String name) {
    final app = _apps.remove(name);
    if (app == null) return;
    _tunnels.remove(name);
    if (app.exitCode == null) {
      app.process.kill(ProcessSignal.sigterm);
      Timer(killGrace, () {
        if (app.exitCode == null) unawaited(_forceKill(app.process));
      });
      // Close only once the process has actually exited: the exit listener
      // registered in _start (which writes the "exited with" line) is
      // attached to this same future first, so it always runs before this.
      unawaited(app.process.exitCode.then((_) => app.log.close()));
    } else {
      unawaited(app.log.close());
    }
  }

  /// SIGKILL, and — when the app runs behind `sudo` — its real child
  /// too. `sudo` relays SIGTERM but cannot relay SIGKILL, which it never
  /// gets to see, so killing only the wrapper leaves the app running with
  /// nothing left holding its handle.
  Future<void> _forceKill(Process process) async {
    if (_wrapped) {
      final children = await _run('/usr/bin/pgrep', ['-P', '${process.pid}']);
      for (final line in children.stdout.toString().split('\n')) {
        final child = int.tryParse(line.trim());
        if (child != null) Process.killPid(child, ProcessSignal.sigkill);
      }
    }
    process.kill(ProcessSignal.sigkill);
  }

  Future<void> stop(String name) async {
    final app = _apps.remove(name);
    if (app == null) return;
    if (app.exitCode == null) {
      app.process.kill(ProcessSignal.sigterm);
      await app.process.exitCode.timeout(
        killGrace,
        // Return the real exit future, not a placeholder: closing the
        // sink while the process is still dying leaves the exit listener
        // (and any last stdout) writing into a closed sink.
        onTimeout: () {
          unawaited(_forceKill(app.process));
          return app.process.exitCode;
        },
      );
    }
    _tunnels.remove(name);
    await app.log.close();
  }

  Future<void> stopAll() async {
    for (final name in _apps.keys.toList()) {
      await stop(name);
    }
  }

  Future<void> restart(Site site) async {
    final wasRunning = _apps.containsKey(site.name);
    await stop(site.name);
    if (wasRunning) await ensureRunning(site);
  }

  /// Stops every app whose last request is older than [idle] and which
  /// has no tunnel open.
  Future<void> stopIdle([DateTime? now]) async {
    final at = now ?? DateTime.now();
    for (final app in _apps.values.toList()) {
      if (_tunnels.containsKey(app.site.name)) continue;
      if (app.ready && at.difference(app.lastRequest) > idle) {
        await stop(app.site.name);
      }
    }
  }

  List<AppStatus> status() => [
    for (final a in _apps.values)
      if (a.exitCode == null)
        AppStatus(
          name: a.site.name,
          port: a.port,
          pid: a.process.pid,
          startedAt: a.startedAt,
          lastRequest: a.lastRequest,
          state: a.ready ? 'running' : 'starting',
        ),
  ];

  /// The last [lines] of the site's log file, or '' when there is none.
  String logTail(String name, [int lines = 40]) {
    final file = File(p.join(logs.path, '$name.log'));
    if (!file.existsSync()) return '';
    final all = const LineSplitter().convert(file.readAsStringSync());
    return all.skip(all.length > lines ? all.length - lines : 0).join('\n');
  }
}
