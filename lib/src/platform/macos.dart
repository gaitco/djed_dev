import 'dart:io';

import 'package:path/path.dart' as p;

import 'platform.dart';

/// Absolute paths throughout: these commands run as root (or become
/// root), and a root process must not let PATH choose which binary that
/// is.
const _sudoBin = '/usr/bin/sudo';
const _launchctlBin = '/bin/launchctl';
const _idBin = '/usr/bin/id';

/// macOS: `/etc/resolver`, the System keychain and launchd. Every
/// privileged call announces itself before `sudo` prompts.
class MacOsPlatform extends DjedPlatform {
  MacOsPlatform({
    Runner? run,
    void Function(String message)? announce,
    Map<String, String>? environment,
  }) : _run = run ?? ((exe, args) => Process.run(exe, args)),
       _announce = announce ?? ((m) => stdout.writeln(m)),
       _environment = environment ?? Platform.environment;

  final Runner _run;
  final void Function(String) _announce;

  /// Injected so the legacy-agent cleanup reads the same `HOME` the rest
  /// of the CLI does, rather than reaching into the process environment
  /// behind its caller's back.
  final Map<String, String> _environment;

  /// A LaunchDaemon, not a LaunchAgent: the daemon has to be root to bind
  /// 80 and 443. Everything that touches it therefore goes through
  /// `sudo`, and the job lives in the `system/` domain.
  static const daemonPlist =
      '/Library/LaunchDaemons/${DjedPlatform.agentLabel}.plist';
  static const _target = 'system/${DjedPlatform.agentLabel}';

  String _resolverFile(String tld) => '/etc/resolver/$tld';

  Future<ProcessResult> _sudoRun(String what, List<String> args) {
    _announce('sudo: $what');
    return _run(_sudoBin, args);
  }

  Future<void> _sudo(String what, List<String> args) async {
    final result = await _sudoRun(what, args);
    if (result.exitCode != 0) {
      throw ProcessException(
        _sudoBin,
        args,
        result.stderr.toString(),
        result.exitCode,
      );
    }
  }

  @override
  Future<void> writeResolver(String tld, int port) async {
    final file = _resolverFile(tld);
    final quoted = "'$file'";
    final content = 'nameserver 127.0.0.1\nport $port\n';
    final script =
        'mkdir -p /etc/resolver; '
        'if [ -f $quoted ] && [ ! -f $quoted.djed-backup ]; then cp $quoted $quoted.djed-backup; fi; '
        "printf '%s' '$content' > $quoted";
    await _sudo('write $file so *.$tld resolves to 127.0.0.1', [
      '/bin/sh',
      '-c',
      script,
    ]);
  }

  @override
  Future<void> removeResolver(String tld) async {
    final file = _resolverFile(tld);
    final quoted = "'$file'";
    final script =
        'if [ -f $quoted.djed-backup ]; then mv $quoted.djed-backup $quoted; else rm -f $quoted; fi';
    await _sudo('remove $file (restoring any backup)', [
      '/bin/sh',
      '-c',
      script,
    ]);
  }

  @override
  Future<void> trustCa(File pem) =>
      _sudo('trust the djed CA in the System keychain', [
        '/usr/bin/security',
        'add-trusted-cert',
        '-d',
        '-r',
        'trustRoot',
        '-k',
        '/Library/Keychains/System.keychain',
        pem.path,
      ]);

  @override
  Future<void> untrustCa(File pem) => _sudo(
    'remove the djed CA from the System keychain',
    ['/usr/bin/security', 'remove-trusted-cert', '-d', pem.path],
  );

  /// launchctl reports failure only through its exit code, so an
  /// unchecked call lets `install` and `start` print success while
  /// nothing was ever loaded. `bootout` on a label that is not loaded
  /// exits 3 ("No such process"), which is the outcome the caller
  /// wanted anyway and so is not an error here.
  Future<void> _launchctl(
    String what,
    List<String> args, {
    bool tolerateMissing = false,
  }) async {
    final result = await _sudoRun(what, [_launchctlBin, ...args]);
    if (result.exitCode == 0) return;
    if (tolerateMissing && result.exitCode == 3) return;
    throw ProcessException(
      _launchctlBin,
      args,
      result.stderr.toString().trim(),
      result.exitCode,
    );
  }

  /// The plist is written unprivileged and then handed to `install(1)`,
  /// which is the one command that copies, chowns and chmods in a single
  /// `sudo`: launchd refuses to load a system plist that is not
  /// `root:wheel` and no wider than 0644.
  @override
  Future<void> installAgent(String plist) async {
    final tmp = Directory.systemTemp.createTempSync('djed_plist');
    try {
      final file = File(p.join(tmp.path, 'djed.plist'));
      await file.writeAsString(plist);
      await _sudo('install the djed LaunchDaemon at $daemonPlist', [
        '/usr/bin/install',
        '-m',
        '0644',
        '-o',
        'root',
        '-g',
        'wheel',
        file.path,
        daemonPlist,
      ]);
    } finally {
      tmp.deleteSync(recursive: true);
    }
    await _removeLegacyAgent();
    // `bootstrap` over a job that is already loaded fails outright, which
    // would make re-running `install` an error.
    await _bootout('unload any djed daemon already loaded');
    await _bootstrap();
  }

  /// launchd's own teardown outlives the `bootout` that asked for it, so
  /// the bootstrap right behind it can lose the race — with the new plist
  /// installed and the old daemon already gone, which is the worst
  /// possible place to give up. One retry, the way [startAgent] already
  /// models.
  Future<void> _bootstrap() async {
    final args = ['bootstrap', 'system', daemonPlist];
    try {
      await _launchctl('load the djed daemon', args);
    } on ProcessException {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await _launchctl('load the djed daemon (retrying)', args);
    }
  }

  /// Versions before the LaunchDaemon installed a per-user LaunchAgent.
  /// Left behind it stays loaded in `gui/<uid>`, losing the race for port
  /// 80 against the root daemon every ten seconds and writing its failure
  /// into the same log. It is the user's own file in the user's own
  /// domain, so no `sudo`; it goes through [_run] rather than `dart:io`
  /// so a test records the removal instead of reaching into a real home.
  Future<void> _removeLegacyAgent() async {
    final uid = (await _run(_idBin, ['-u'])).stdout.toString().trim();
    if (uid.isEmpty) return;
    final plist = p.join(
      _environment['HOME'] ?? '',
      'Library',
      'LaunchAgents',
      '${DjedPlatform.agentLabel}.plist',
    );
    // Both may legitimately find nothing; neither exit code is news.
    await _run(_launchctlBin, [
      'bootout',
      'gui/$uid/${DjedPlatform.agentLabel}',
    ]);
    await _run('/bin/rm', ['-f', plist]);
  }

  /// `bootout` exits 3 ("No such process") when nothing is loaded, which
  /// is the outcome every caller wanted anyway.
  Future<void> _bootout([String what = 'stop the djed daemon']) =>
      _launchctl(what, ['bootout', _target], tolerateMissing: true);

  @override
  Future<void> uninstallAgent() async {
    await _removeLegacyAgent();
    await _bootout();
    await _sudo('remove $daemonPlist', ['/bin/rm', '-f', daemonPlist]);
  }

  @override
  Future<void> startAgent() async {
    final kick = await _sudoRun('start the djed daemon', [
      _launchctlBin,
      'kickstart',
      '-k',
      _target,
    ]);
    if (kick.exitCode == 0) return;
    // [stopAgent] boots the job out of the domain, so there may be
    // nothing left to kickstart: load the installed plist again first.
    await _bootstrap();
    await _launchctl('start the djed daemon', ['kickstart', '-k', _target]);
  }

  /// `launchctl stop` on a `KeepAlive` job means "restart it": stopping
  /// for real is booting the job out of the domain, exactly as
  /// [uninstallAgent] does. [startAgent]'s `kickstart` loads it again.
  @override
  Future<void> stopAgent() => _bootout();

  @override
  Future<bool> agentRunning() async {
    final result = await _sudoRun('ask launchd about the djed daemon', [
      _launchctlBin,
      'print',
      _target,
    ]);
    return result.exitCode == 0 &&
        result.stdout.toString().contains('state = running');
  }

  @override
  Future<List<PortOwner>> listeners(List<int> ports) async {
    final result = await _run('lsof', [
      '-nP',
      ...ports.map((p) => '-iTCP:$p'),
      '-sTCP:LISTEN',
    ]);
    final owners = <PortOwner>[];
    for (final line in result.stdout.toString().split('\n').skip(1)) {
      final cols = line.trim().split(RegExp(r'\s+'));
      if (cols.length < 9) continue;
      final port = int.tryParse(
        cols.last == '(LISTEN)'
            ? cols[cols.length - 2].split(':').last
            : cols.last.split(':').last,
      );
      final pid = int.tryParse(cols[1]);
      if (port == null || pid == null) continue;
      owners.add(PortOwner(port, pid, cols[0]));
    }
    return owners;
  }

  @override
  Future<void> openUrl(String url) async {
    await _run('open', [url]);
  }
}
