import 'dart:io';

import '../config.dart';
import '../sites.dart';
import '../tls/certificates.dart';
import 'runner.dart';

/// Whose machine this is — the account the root LaunchDaemon hands its
/// files and its application processes back to.
///
/// `USER`, then `id -un`. `SUDO_USER` is deliberately not consulted:
/// `install` refuses to run under `sudo` at all, because sudo also sets
/// `HOME=/var/root` and every path would land in root's home while
/// `DJED_USER` named the human. `null` when the answer is empty or
/// root, which would defeat the point of dropping privileges.
Future<String?> consoleUser([Map<String, String>? environment]) async {
  final env = environment ?? Platform.environment;
  var name = env['USER'] ?? '';
  if (name.isEmpty) {
    final result = await Process.run('/usr/bin/id', ['-un']);
    if (result.exitCode == 0) name = result.stdout.toString().trim();
  }
  return name.isEmpty || name == 'root' ? null : name;
}

/// Whether the system knows [user]. A typo caught here fails once, with
/// the name in it, instead of once per site in a log nobody is reading.
Future<bool> accountExists(String user) async =>
    (await Process.run('/usr/bin/id', ['-u', user])).exitCode == 0;

class InstallCommand extends DjedCommand {
  InstallCommand(super.context);
  @override
  String get name => 'install';
  @override
  String get description =>
      'Set up DNS, certificates and the background daemon';

  @override
  Future<int> run() async {
    var config = await context.config();
    if (!await context.portsFree(config)) return 1;
    final user = await consoleUser(context.environment);
    if (user == null) {
      err.writeln(
        'djed could not tell whose machine this is: neither SUDO_USER, '
        'USER nor `id -un` names a non-root account.',
      );
      err.writeln(
        'Run `djed install` as yourself (it asks for sudo where it '
        'needs to), not from a root shell.',
      );
      return 1;
    }
    if (!await accountExists(user)) {
      err.writeln('No account named \'$user\' on this machine.');
      err.writeln(
        'djed would write it into the LaunchDaemon as DJED_USER and '
        'every application would fail to start.',
      );
      return 1;
    }
    config = config.copyWith(
      openssl: await _resolve(context.openssl),
      dart: await _resolve(defaultDartExecutable()),
    );
    await config.save(paths);
    final certs = Certificates(paths, openssl: config.openssl);
    await certs.ensureCa();
    await certs.ensureLeaf(
      config.tld,
      sites: SiteRegistry(config).all().map((s) => s.name).toList(),
    );
    await platform.trustCa(paths.caCert);
    await platform.writeResolver(config.tld, config.dnsPort);
    await platform.installAgent(
      platform.launchdPlist(
        context.daemonCommand,
        paths,
        user: user,
        openssl: config.openssl,
      ),
    );
    await platform.startAgent();
    out.writeln('djed installed. Park a directory with: djed park');
    return 0;
  }

  /// Pins a binary to an absolute path once, at install time: launchd
  /// gives the daemon a bare `/usr/bin:/bin:/usr/sbin:/sbin` PATH, where
  /// `openssl` is macOS's LibreSSL rather than the one on the shell's
  /// PATH and `dart` does not appear at all.
  Future<String> _resolve(String command) async {
    final which = await Process.run('which', [command]);
    final path = which.stdout.toString().trim();
    return which.exitCode == 0 && path.isNotEmpty ? path : command;
  }
}

class UninstallCommand extends DjedCommand {
  UninstallCommand(super.context) {
    argParser.addFlag(
      'purge',
      help: 'Also delete config and logs',
      negatable: false,
    );
  }
  @override
  String get name => 'uninstall';
  @override
  String get description => 'Remove the daemon, DNS resolver and CA';

  @override
  Future<int> run() async {
    final config = await context.config();
    await platform.stopAgent();
    await platform.uninstallAgent();
    await platform.removeResolver(config.tld);
    await platform.untrustCa(paths.caCert);
    for (final dir in [paths.caKey.parent, paths.leafKey.parent]) {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    }
    if (argResults!.flag('purge') && paths.home.existsSync()) {
      paths.home.deleteSync(recursive: true);
    }
    out.writeln('djed uninstalled.');
    return 0;
  }
}

class SecureCommand extends DjedCommand {
  SecureCommand(super.context) {
    argParser.addFlag(
      'restart',
      negatable: false,
      help: 'Restart the daemon afterwards',
    );
  }
  @override
  String get name => 'secure';
  @override
  String get description =>
      "Regenerate every site's certificate and trust the CA";
  @override
  Future<int> run() async {
    final config = await context.config();
    final certs = Certificates(paths, openssl: config.openssl);
    await certs.ensureCa();
    await certs.ensureLeaf(
      config.tld,
      sites: SiteRegistry(config).all().map((s) => s.name).toList(),
      force: true,
    );
    await platform.trustCa(paths.caCert);
    if (argResults!.flag('restart')) {
      await platform.stopAgent();
      await platform.startAgent();
      out.writeln('Certificate renewed; daemon restarted.');
    } else {
      out.writeln('Certificate renewed. Restart the daemon: djed restart');
    }
    return 0;
  }
}
