import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:path/path.dart' as p;

import '../config.dart';
import '../control.dart';
import '../platform/platform.dart';
import '../tls/certificates.dart';
import 'commands_daemon.dart';
import 'commands_install.dart';
import 'commands_sites.dart';

export 'commands_daemon.dart';
export 'commands_install.dart';
export 'commands_sites.dart';

/// Shared state every command needs.
class DjedContext {
  DjedContext({
    required this.platform,
    required this.paths,
    required this.out,
    required this.err,
    required this.daemonCommand,
    required this.controlFactory,
    this.openssl = 'openssl',
    Map<String, String>? environment,
  }) : environment = environment ?? Platform.environment;

  final DjedPlatform platform;
  final DjedPaths paths;
  final StringSink out;
  final StringSink err;

  /// The argv launchd is told to run; see [defaultDaemonCommand].
  final List<String> daemonCommand;
  final Future<ControlClient?> Function(DjedPaths) controlFactory;
  final String openssl;

  /// The process environment, injectable so `install`'s refusal to run
  /// under `sudo` can be tested without one.
  final Map<String, String> environment;

  Future<DjedConfig> config() => DjedConfig.load(paths);

  Future<ControlClient?> control() => controlFactory(paths);

  Future<void> reload() async {
    final client = await control();
    if (client == null) return;
    try {
      await client.send({'cmd': 'reload'});
    } catch (_) {
      // daemon not running; the file change is enough
    }
  }

  /// Exit 1 with a message when something else holds the proxy ports.
  Future<bool> portsFree(DjedConfig config) async {
    final owners = await platform.listeners([
      config.httpPort,
      config.httpsPort,
    ]);
    if (owners.isEmpty) return true;
    for (final o in owners) {
      err.writeln('Port ${o.port} is used by ${o.command} (pid ${o.pid}).');
    }
    if (owners.any((o) => o.command.startsWith('nginx'))) {
      err.writeln('Stop Herd with: herd stop   or Valet with: valet stop');
    }
    err.writeln('djed needs ports ${config.httpPort} and ${config.httpsPort}.');
    return false;
  }
}

/// What launchd must exec to run the daemon.
///
/// `Platform.resolvedExecutable` alone is the `dart` binary whenever
/// djed was installed with `dart pub global activate`, so a plist built
/// from it runs a bare VM with a `daemon` argument it ignores, fails, and
/// gets respawned by `KeepAlive` every ten seconds. The script and the
/// VM's own arguments have to be spelled out.
List<String> defaultDaemonCommand() => daemonCommandFor(
  executable: Platform.resolvedExecutable,
  executableArguments: Platform.executableArguments,
  script: Platform.script.toFilePath(),
);

/// The VM's own view of how this process was started, turned into the
/// command launchd should exec.
///
/// Split out from [defaultDaemonCommand] because the two shapes cannot
/// both be produced inside one test run: a `dart compile exe` binary is
/// its own script — executable, script and argv[0] are all the same path
/// — so spelling the script out again would hand the daemon its own path
/// as a command name, and launchd would respawn that failure every ten
/// seconds.
List<String> daemonCommandFor({
  required String executable,
  required List<String> executableArguments,
  required String script,
}) => p.equals(executable, script)
    ? [executable, 'daemon']
    : [executable, ...executableArguments, script, 'daemon'];

Future<int> runDjed(
  List<String> args, {
  required DjedPlatform platform,
  required DjedPaths paths,
  StringSink? out,
  StringSink? err,
  Future<ControlClient?> Function(DjedPaths)? controlFactory,
  List<String>? daemonCommand,
  String openssl = 'openssl',
  Map<String, String>? environment,
}) async {
  final context = DjedContext(
    platform: platform,
    paths: paths,
    out: out ?? stdout,
    err: err ?? stderr,
    daemonCommand: daemonCommand ?? defaultDaemonCommand(),
    openssl: openssl,
    environment: environment,
    controlFactory:
        controlFactory ??
        (paths) async {
          final client = ControlClient(paths.socket);
          return await client.alive ? client : null;
        },
  );
  final runner =
      CommandRunner<int>('djed', 'Local *.test environment for Maat apps.')
        ..addCommand(InstallCommand(context))
        ..addCommand(UninstallCommand(context))
        ..addCommand(StartCommand(context))
        ..addCommand(StopCommand(context))
        ..addCommand(RestartCommand(context))
        ..addCommand(StatusCommand(context))
        ..addCommand(ParkCommand(context))
        ..addCommand(ForgetCommand(context))
        ..addCommand(LinkCommand(context))
        ..addCommand(UnlinkCommand(context))
        ..addCommand(LinksCommand(context))
        ..addCommand(LogCommand(context))
        ..addCommand(OpenCommand(context))
        ..addCommand(SecureCommand(context))
        ..addCommand(DaemonCommand(context));
  // sudo sets HOME=/var/root, so every path djed computes would land in
  // root's home: `install` would write a config the user can never see,
  // and `uninstall`, `secure`, `start` and the rest would quietly operate
  // on the wrong home. djed asks for sudo itself, exactly where it
  // needs it, so there is never a reason to be under one here.
  if (context.environment.containsKey('SUDO_USER')) {
    context.err.writeln('Run djed as yourself, without sudo.');
    context.err.writeln(
      'It asks for sudo on its own where it needs it — for /etc/resolver, '
      'the System keychain and the LaunchDaemon — and needs your own HOME '
      'for everything else.',
    );
    return 1;
  }
  try {
    return await runner.run(args) ?? 0;
  } on UsageException catch (e) {
    context.err.writeln(e.message);
    context.err.writeln();
    context.err.writeln(e.usage);
    return 64;
  } on OpensslFailed catch (e) {
    context.err.writeln(e.message);
    context.err.writeln('Install OpenSSL (brew install openssl) and re-run.');
    return 1;
  } on PermissionsFailed catch (e) {
    // Its own arm: this used to surface as OpensslFailed, so a directory
    // the user no longer owned was reported as a missing OpenSSL.
    context.err.writeln(e.message);
    context.err.writeln(
      'Check that ${paths.home.path} and everything under it belongs to you.',
    );
    return 1;
  } on ProcessException catch (e) {
    // launchctl, security and sudo all report failure through an exit
    // code the platform layer turns into this; without it a failed
    // bootstrap would print success.
    context.err.writeln(
      'djed: ${e.executable} ${e.arguments.join(' ')} failed'
      '${e.errorCode == 0 ? '' : ' (exit ${e.errorCode})'}'
      '${e.message.isEmpty ? '' : ': ${e.message}'}',
    );
    return 1;
  } catch (e) {
    context.err.writeln('djed: $e');
    return 1;
  }
}

/// Base every command extends: shared access to [DjedContext]'s pieces.
abstract class DjedCommand extends Command<int> {
  DjedCommand(this.context);
  final DjedContext context;
  StringSink get out => context.out;
  StringSink get err => context.err;
  DjedPaths get paths => context.paths;
  DjedPlatform get platform => context.platform;
}
