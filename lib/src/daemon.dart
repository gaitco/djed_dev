import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'apps/app_runner.dart';
import 'apps/watcher.dart';
import 'config.dart';
import 'control.dart';
import 'dns/responder.dart';
import 'platform/platform.dart';
import 'proxy/proxy_server.dart';
import 'sites.dart';
import 'tls/certificates.dart';

/// Wires DNS, proxy, app runner, watchers and the control socket.
class Daemon {
  Daemon({
    required this.paths,
    required DjedConfig config,
    this.securityContext,
    this.certificates,
    InternetAddress? address,
    void Function(String message)? log,
    String? runAsUser,
    bool? runningAsRoot,
    Runner? run,
  }) : _config = config, // ignore: prefer_initializing_formals
       address = address ?? InternetAddress.loopbackIPv4,
       runAsUser = runAsUser ?? Platform.environment['DJED_USER'],
       runningAsRoot = runningAsRoot ?? runningAsRootProcess,
       _run = run ?? ((exe, args) => Process.run(exe, args)),
       _log =
           log ??
           ((m) => stdout.writeln('[${DateTime.now().toIso8601String()}] $m'));

  final DjedPaths paths;

  /// The console user, from `DJED_USER` in the LaunchDaemon's plist.
  /// The daemon runs as root because nothing else may bind 80 and 443,
  /// but every file it owns and every app it starts belong to this user.
  /// `null` (or a daemon that is not root) means there is nothing to give
  /// back, which is how the tests and a foreground `djed daemon` run.
  final String? runAsUser;
  final bool runningAsRoot;

  final Runner _run;

  /// Used only when [certificates] is absent, or its CA hasn't been
  /// created yet: callers (tests, mainly) that manage a certificate
  /// themselves can still hand the daemon a ready [SecurityContext].
  /// When both are given, [certificates] wins.
  final SecurityContext? securityContext;

  /// When given (and its CA already exists), the daemon regenerates the
  /// leaf's SANs to match the current sites on [start] and [reload], and
  /// rebinds HTTPS whenever that regeneration actually changes the leaf.
  final Certificates? certificates;

  final InternetAddress address;
  final void Function(String) _log;

  DjedConfig _config;
  late SiteRegistry _sites;
  late AppRunner _runner;
  late ProxyServer _proxy;
  late DnsResponder _dns;
  ServerSocket? _control;
  HttpServer? _https;
  Timer? _idleTimer;
  final _watchers = <String, ChangeWatcher>{};
  final _startedAt = DateTime.now();

  /// Set only once `start()` has finished wiring everything up, so `stop()`
  /// on a daemon whose `start()` failed partway through (e.g. the pid
  /// guard) has nothing `late`-uninitialised left to touch.
  bool _started = false;

  int get httpPort => _proxy.servers.first.port;
  int get httpsPort => _https?.port ?? 0;
  int get dnsPort => _dns.boundPort;

  bool get _dropsPrivileges => runAsUser != null && runningAsRoot;

  /// Hands back what root just created. `~/.config/djed` is the
  /// developer's own directory: its config, certificates and logs must
  /// stay editable and readable by them, not by root alone.
  Future<void> _giveBack(List<String> args, String what) async {
    final result = await _run(args.first, args.sublist(1));
    if (result.exitCode != 0) _log('$what failed: ${result.stderr}');
  }

  /// Run both before and after everything root writes during a start: the
  /// leaf certificate, its key, `ca.srl` and the pid file are all created
  /// after the first pass, and a root-owned leaf key is exactly what
  /// makes a later `djed secure` fail for the user.
  Future<void> _chownHome() async {
    if (!_dropsPrivileges) return;
    await _giveBack([
      '/usr/sbin/chown',
      '-R',
      runAsUser!,
      paths.home.path,
    ], 'chown ${paths.home.path} to $runAsUser');
  }

  /// Root must not take orders from a file the console user owns — this
  /// daemon chowns `config.json` to them.
  ///
  /// The only capability root adds is a port below 1024, so that is the
  /// only thing this file may not choose: 80 and 443 are what `install`
  /// wrote and what the tool exists to serve, and DNS never needs a
  /// privileged port at all (`install` writes 53535 and `/etc/resolver`
  /// points there). Ports at or above 1024 are left alone — binding one
  /// is something the user could already do without root, so it is not a
  /// privilege this guard is protecting. `openssl` is ignored outright;
  /// see `DaemonCommand`.
  ///
  /// Called from [start] *and* [reload]: `djed link`, `park`, `forget`
  /// and `unlink` all reload, and a reload that changes the site list
  /// rebinds HTTPS from whatever this file now says.
  void _guardPorts(DjedConfig config) {
    if (!runningAsRoot) return;
    void refuse(String key, int port, String allowed) => throw StateError(
      'refusing to bind privileged port $port as root: ${paths.config.path} '
      'belongs to you, not to root, so $key may only be $allowed.',
    );
    if (config.httpPort < 1024 && config.httpPort != 80) {
      refuse('httpPort', config.httpPort, '80 or a port above 1023');
    }
    if (config.httpsPort < 1024 && config.httpsPort != 443) {
      refuse('httpsPort', config.httpsPort, '443 or a port above 1023');
    }
    if (config.dnsPort < 1024) {
      refuse('dnsPort', config.dnsPort, 'a port above 1023');
    }
  }

  /// What only [start] can check: a root process with no user to hand
  /// anything back to must not run at all.
  void _guardUser() {
    if (runningAsRoot && runAsUser == null) {
      throw StateError(
        'djed is running as root with no DJED_USER: it would start '
        'every application as root and leave your project files, caches '
        'and databases owned by root. Re-run `djed install` to write a '
        'LaunchDaemon that sets DJED_USER.',
      );
    }
  }

  Future<void> start() async {
    _guardUser();
    _guardPorts(_config);
    paths.ensureDirectories();
    await _chownHome();
    _guardPid();
    await rotateLog(paths.daemonLog);
    _sites = SiteRegistry(_config);
    _runner = AppRunner(
      tld: _config.tld,
      logs: paths.logs,
      idle: Duration(minutes: _config.idleMinutes),
      startTimeout: Duration(seconds: _config.startTimeoutSeconds),
      runAsUser: runAsUser,
      runningAsRoot: runningAsRoot,
      command: appCommandFor(_config.dart),
    );
    _proxy = ProxyServer(sites: _sites, runner: _runner, log: _log);
    await _proxy.listen(address, _config.httpPort);
    final tls = await _tlsContext(_sites.all().map((s) => s.name).toList());
    if (tls != null) {
      _https = await _proxy.listen(address, _config.httpsPort, context: tls);
    }
    _dns = DnsResponder(
      tld: _config.tld,
      port: _config.dnsPort,
      address: address,
      onError: (e) => _log('dns: $e'),
    );
    await _dns.start();
    await _listenControl();
    _idleTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      _guard(_runner.stopIdle(), 'idle sweep');
      _guard(rotateLog(paths.daemonLog), 'log rotation');
    });
    await _watchSites();
    paths.pidFile.writeAsStringSync('$pid');
    await _chownHome();
    _started = true;
    _log(
      'djed daemon $pid: http :${_config.httpPort} https :${_config.httpsPort} dns :${_config.dnsPort} tld .${_config.tld}',
    );
  }

  /// The [SecurityContext] to bind HTTPS with, or `null` to skip HTTPS
  /// entirely. When [certificates] is set and already has a CA, this
  /// (re)generates the leaf for the current [siteNames] - forced when the
  /// existing leaf is within 30 days of expiring, otherwise only when the
  /// wanted SAN set actually differs - and returns its context. Otherwise
  /// falls back to the plain [securityContext] a caller supplied.
  Future<SecurityContext?> _tlsContext(List<String> siteNames) async {
    final certs = certificates;
    if (certs == null || !certs.caExists) return securityContext;
    final expiring = await certs.leafExpiresWithin(const Duration(days: 30));
    await certs.ensureLeaf(_config.tld, sites: siteNames, force: expiring);
    return certs.securityContext();
  }

  void _guardPid() {
    if (!paths.pidFile.existsSync()) return;
    final other = int.tryParse(paths.pidFile.readAsStringSync().trim());
    // Deliberately not exempting our own pid: a stale file left by a
    // process the OS has since reused this pid for looks identical to
    // "still running" from here, and refusing is the safe default either
    // way — a real second start never legitimately shares the pid file
    // owner's process.
    if (other != null && _alive(other)) {
      throw StateError('djed daemon already running with pid $other');
    }
  }

  bool _alive(int pid) =>
      Process.runSync('/bin/kill', ['-0', '$pid']).exitCode == 0;

  Future<void> _listenControl() async {
    if (paths.socket.existsSync()) paths.socket.deleteSync();
    final server = await ServerSocket.bind(
      InternetAddress(paths.socket.path, type: InternetAddressType.unix),
      0,
    );
    _control = server;
    if (_dropsPrivileges) {
      // Bound by root, but the CLI that talks to it is the user's: give
      // them the socket, and only them (0600 — anyone who can write here
      // can restart the daemon and every app under it).
      await _giveBack([
        '/usr/sbin/chown',
        runAsUser!,
        paths.socket.path,
      ], 'chown ${paths.socket.path} to $runAsUser');
      await _giveBack([
        '/bin/chmod',
        '0600',
        paths.socket.path,
      ], 'chmod 0600 ${paths.socket.path}');
    }
    server.listen((socket) async {
      try {
        final line = await utf8.decoder
            .bind(socket)
            .transform(const LineSplitter())
            .first;
        final command = jsonDecode(line) as Map<String, Object?>;
        final reply = await _handleControl(command);
        socket.writeln(jsonEncode(reply));
      } catch (e) {
        try {
          socket.writeln(jsonEncode({'error': e.toString()}));
        } catch (writeError) {
          // The peer may already have closed its side between the read
          // and this write. Log rather than throw again out of a
          // listener callback.
          _log('control: failed to write error response: $writeError');
        }
      } finally {
        try {
          await socket.flush();
        } catch (e) {
          // The peer may already have closed its side; a closed peer must
          // not surface as an unhandled async error out of this listener.
          _log('control: failed to flush response: $e');
        }
        socket.destroy();
      }
    }, onError: (Object e) => _log('control: $e'));
  }

  Future<Map<String, Object?>> _handleControl(
    Map<String, Object?> command,
  ) async {
    switch (command['cmd']) {
      case 'status':
        return statusJson();
      case 'reload':
        await reload();
        return {'ok': true};
      case 'restart':
        final site = _sites.find(command['site'] as String? ?? '');
        if (site == null) return {'error': 'unknown site ${command['site']}'};
        await _runner.restart(site);
        return {'ok': true};
      case 'stop-site':
        await _runner.stop(command['site'] as String? ?? '');
        return {'ok': true};
      case 'shutdown':
        _guard(
          Future<void>.delayed(const Duration(milliseconds: 50), stop),
          'shutdown',
        );
        return {'ok': true};
      default:
        return {'error': 'unknown command ${command['cmd']}'};
    }
  }

  Map<String, Object?> statusJson() => {
    'pid': pid,
    'startedAt': _startedAt.toIso8601String(),
    'tld': _config.tld,
    'httpPort': httpPort,
    'httpsPort': httpsPort,
    'dnsPort': dnsPort,
    'sites': [
      for (final s in _sites.all())
        {'name': s.name, 'path': s.path, 'url': _config.url(s.name)},
    ],
    'apps': [for (final a in _runner.status()) a.toJson()],
  };

  /// Re-reads config.json; sites, watchers, running apps for sites that
  /// disappeared, and (when [certificates] manages the leaf) the HTTPS
  /// certificate all follow.
  Future<void> reload() async {
    final config = await DjedConfig.load(paths);
    // Before anything is applied, so a refused reload leaves the daemon
    // serving exactly what it was serving.
    _guardPorts(config);
    _config = config;
    _sites = SiteRegistry(_config);
    _proxy.sites = _sites;
    final registered = {for (final s in _sites.all()) s.name};
    for (final app in _runner.status()) {
      if (!registered.contains(app.name)) await _runner.stop(app.name);
    }
    await _watchSites();
    final certs = certificates;
    if (certs != null && certs.caExists) {
      final names = _sites.all().map((s) => s.name).toList();
      final regenerated = await certs.ensureLeaf(_config.tld, sites: names);
      if (regenerated && _https != null) {
        _https = await _proxy.rebind(
          _https!,
          address,
          _config.httpsPort,
          context: certs.securityContext(),
        );
        _log('https rebound: certificate SANs changed');
      }
    }
    // A regenerated leaf and its key were written by root a moment ago.
    await _chownHome();
    _log('config reloaded: ${_sites.all().length} site(s)');
  }

  Future<void> _watchSites() async {
    final wanted = {for (final s in _sites.all()) s.name: s};
    for (final name in _watchers.keys.toList()) {
      // A link can be repointed to a new path while keeping the same
      // name; the old watcher would otherwise keep watching the stale
      // path forever, and the "already watching this name" check below
      // would never replace it.
      final site = wanted[name];
      if (site == null || site.path != _watchers[name]!.site.path) {
        await _watchers.remove(name)!.stop();
      }
    }
    for (final site in wanted.values) {
      if (_watchers.containsKey(site.name)) continue;
      final watcher = ChangeWatcher(site, () {
        _log('${site.name}: code changed, restarting');
        // A save that does not compile makes restart() throw
        // StartFailed. Unhandled, that error leaves the root zone and
        // kills the daemon — orphaning every other app — for what is a
        // normal editing mistake. The proxy renders the failure as a 502
        // on the next request instead.
        _guard(_runner.restart(site), 'restarting ${site.name}');
      });
      await watcher.start();
      _watchers[site.name] = watcher;
    }
  }

  /// Runs [work] to completion in the background, logging a failure
  /// instead of letting it escape to the root zone and take the process
  /// down. Everything the daemon starts and does not await goes through
  /// here.
  void _guard(Future<void> work, String what) {
    unawaited(work.catchError((Object e) => _log('$what failed: $e')));
  }

  Future<void> stop() async {
    if (!_started) return;
    _started = false;
    _idleTimer?.cancel();
    for (final w in _watchers.values) {
      await w.stop();
    }
    _watchers.clear();
    await _control?.close();
    if (paths.socket.existsSync()) paths.socket.deleteSync();
    await _dns.stop();
    await _proxy.close();
    await _runner.stopAll();
    if (paths.pidFile.existsSync()) paths.pidFile.deleteSync();
    _log('djed daemon stopped');
  }
}
