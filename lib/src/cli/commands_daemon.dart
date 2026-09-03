import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../apps/app_runner.dart';
import '../config.dart';
import '../daemon.dart';
import '../dns/packet.dart';
import '../sites.dart';
import '../tls/certificates.dart';
import 'runner.dart';

class StartCommand extends DjedCommand {
  StartCommand(super.context);
  @override
  String get name => 'start';
  @override
  String get description => 'Start the daemon';
  @override
  Future<int> run() async {
    if (!await context.portsFree(await context.config())) return 1;
    await platform.startAgent();
    out.writeln('djed started.');
    return 0;
  }
}

class StopCommand extends DjedCommand {
  StopCommand(super.context);
  @override
  String get name => 'stop';
  @override
  String get description => 'Stop the daemon and every app';
  @override
  Future<int> run() async {
    await platform.stopAgent();
    out.writeln('djed stopped.');
    return 0;
  }
}

class RestartCommand extends DjedCommand {
  RestartCommand(super.context);
  @override
  String get name => 'restart';
  @override
  String get description =>
      'Restart the daemon, or one site: djed restart blog';
  @override
  Future<int> run() async {
    final site = argResults!.rest.firstOrNull;
    if (site == null) {
      await platform.stopAgent();
      await platform.startAgent();
      out.writeln('djed restarted.');
      return 0;
    }
    final client = await context.control();
    if (client == null) {
      err.writeln('Daemon: not running');
      return 1;
    }
    await client.send({'cmd': 'restart', 'site': site});
    out.writeln('$site restarted.');
    return 0;
  }
}

class StatusCommand extends DjedCommand {
  StatusCommand(super.context);
  @override
  String get name => 'status';
  @override
  String get description =>
      'Show the daemon, DNS, certificate and running apps';

  @override
  Future<int> run() async {
    final config = await context.config();
    final client = await context.control();
    if (client == null) {
      out.writeln('Daemon: not running');
      out.writeln(
        'Config: ${paths.config.path} (tld .${config.tld}, ${config.paths.length} parked, ${config.links.length} linked)',
      );
      return 1;
    }
    final status = await client.send({'cmd': 'status'});
    out.writeln(
      'Daemon: running (pid ${status['pid']}) since ${status['startedAt']}',
    );
    out.writeln(
      'Ports: http ${status['httpPort']}, https ${status['httpsPort']}, dns ${status['dnsPort']}, tld .${status['tld']}',
    );
    final expiry = await Certificates(
      paths,
      openssl: config.openssl,
    ).leafExpiry();
    out.writeln(
      'Certificate: ${expiry == null ? 'missing' : 'expires ${expiry.toIso8601String().split('T').first}'}',
    );
    out.writeln('DNS: ${await _dnsOk(config) ? 'ok' : 'no answer'}');
    final apps = (status['apps'] as List).cast<Map<String, Object?>>();
    if (apps.isEmpty) {
      out.writeln('Apps: none running');
      return 0;
    }
    out.writeln('Apps:');
    for (final a in apps) {
      final idle = DateTime.now()
          .difference(DateTime.parse(a['lastRequest'] as String))
          .inSeconds;
      out.writeln(
        '  ${a['name']}  port ${a['port']}  pid ${a['pid']}  ${a['state']}  idle ${idle}s',
      );
    }
    return 0;
  }

  /// Sends a real query to the DNS responder and reads the reply inside the
  /// socket listener: a `.first`-on-the-event-stream + separate `receive()`
  /// races here, because cancelling the subscription on match can discard
  /// the datagram `RawDatagramSocket` already buffered before `receive()`
  /// gets a chance to read it (see `test/dns_responder_test.dart`).
  Future<bool> _dnsOk(DjedConfig config) async {
    RawDatagramSocket? socket;
    StreamSubscription<RawSocketEvent>? subscription;
    try {
      socket = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      final name = 'djed-check.${config.tld}';
      final bytes = <int>[0, 7, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0];
      for (final label in name.split('.')) {
        bytes
          ..add(label.length)
          ..addAll(label.codeUnits);
      }
      bytes.addAll([0, 0, dnsTypeA, 0, 1]);
      final reply = Completer<Uint8List>();
      subscription = socket.listen((event) {
        if (event != RawSocketEvent.read) return;
        final datagram = socket!.receive();
        if (datagram != null && !reply.isCompleted) {
          reply.complete(datagram.data);
        }
      });
      socket.send(
        Uint8List.fromList(bytes),
        InternetAddress.loopbackIPv4,
        config.dnsPort,
      );
      final data = await reply.future.timeout(const Duration(seconds: 1));
      return data.length >= 4 && (data[3] & 0x0f) == rcodeNoError;
    } catch (_) {
      return false;
    } finally {
      await subscription?.cancel();
      socket?.close();
    }
  }
}

class LogCommand extends DjedCommand {
  LogCommand(super.context) {
    argParser.addFlag(
      'follow',
      abbr: 'f',
      negatable: false,
      help: 'Keep printing new lines',
    );
  }
  @override
  String get name => 'log';
  @override
  String get description => 'Show the daemon log, or a site log: djed log blog';
  @override
  Future<int> run() async {
    final site = argResults!.rest.firstOrNull;
    // The daemon names log files after the normalized site name, which is
    // what `link` and the registry both use.
    final file = site == null
        ? paths.daemonLog
        : paths.siteLog(normalizeSiteName(site));
    if (!file.existsSync()) {
      err.writeln('No log at ${file.path}');
      return 1;
    }
    var offset = 0;
    void dump() {
      final length = file.lengthSync();
      if (length <= offset) return;
      final raf = file.openSync()..setPositionSync(offset);
      // allowMalformed: a follow can land mid-codepoint, and log bytes are
      // whatever the app wrote; fromCharCodes would mangle every non-ASCII
      // character rather than just the split one.
      out.write(
        utf8.decode(raf.readSync(length - offset), allowMalformed: true),
      );
      raf.closeSync();
      offset = length;
    }

    dump();
    if (!argResults!.flag('follow')) return 0;
    while (true) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      dump();
    }
  }
}

class DaemonCommand extends DjedCommand {
  DaemonCommand(super.context);
  @override
  String get name => 'daemon';
  @override
  String get description =>
      'Run the daemon in the foreground (what launchd runs)';
  @override
  Future<int> run() async {
    final config = await context.config();
    // config.json is chowned to the console user, so as root it is
    // untrusted input: `openssl` there names a binary this process would
    // exec as root. Ignored outright — Certificates falls back to
    // DJED_OPENSSL from the root-owned plist, then to PATH. The CLI
    // keeps using the config value; it is the user either way.
    final certs = Certificates(
      paths,
      openssl: runningAsRootProcess ? null : config.openssl,
    );
    final daemon = Daemon(
      paths: paths,
      config: config,
      certificates: certs.caExists ? certs : null,
    );
    await daemon.start();
    final done = Completer<void>();
    for (final signal in [ProcessSignal.sigterm, ProcessSignal.sigint]) {
      signal.watch().listen((_) {
        if (!done.isCompleted) done.complete();
      });
    }
    await done.future;
    await daemon.stop();
    return 0;
  }
}
