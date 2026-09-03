import 'dart:io';

import '../config.dart';

/// How a subprocess is run. Injectable everywhere a privileged command
/// is issued, so tests record instead of running them.
typedef Runner =
    Future<ProcessResult> Function(String executable, List<String> args);

class PortOwner {
  const PortOwner(this.port, this.pid, this.command);
  final int port;
  final int pid;
  final String command;
}

/// The OS-specific and privileged steps, kept behind one door so the CLI
/// can be tested with a fake.
abstract class DjedPlatform {
  static const agentLabel = 'com.maat.djed';

  Future<void> writeResolver(String tld, int port);
  Future<void> removeResolver(String tld);
  Future<void> trustCa(File pem);
  Future<void> untrustCa(File pem);
  Future<void> installAgent(String plist);
  Future<void> uninstallAgent();
  Future<void> startAgent();
  Future<void> stopAgent();
  Future<bool> agentRunning();
  Future<List<PortOwner>> listeners(List<int> ports);
  Future<void> openUrl(String url);

  /// A **LaunchDaemon**, deliberately: only root may bind ports below
  /// 1024, and `https://name.test` with no port is the whole point of
  /// this tool. So there is no `UserName` key — a job bootstrapped into
  /// `system/` runs as root — and [user], the console user, travels in
  /// `DJED_USER` instead: the daemon hands its files back to that user
  /// and spawns every application as them. Valet and Herd do the same.
  ///
  /// [command] is the whole argv launchd must exec, not just a binary:
  /// see `defaultDaemonCommand` for why the script path can never be
  /// left implicit. [openssl], when given, is exported as
  /// `DJED_OPENSSL` so the daemon uses the same binary `install`
  /// resolved rather than whatever launchd's own PATH turns up.
  String launchdPlist(
    List<String> command,
    DjedPaths paths, {
    required String user,
    String? openssl,
  }) =>
      '''
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$agentLabel</string>
  <key>ProgramArguments</key>
  <array>
${command.map((a) => '    <string>${_xml(a)}</string>').join('\n')}
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>DJED_HOME</key><string>${_xml(paths.home.path)}</string>
    <key>DJED_USER</key><string>${_xml(user)}</string>
${openssl == null ? '' : '    <key>DJED_OPENSSL</key><string>${_xml(openssl)}</string>\n'}  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>${_xml(paths.daemonLog.path)}</string>
  <key>StandardErrorPath</key><string>${_xml(paths.daemonLog.path)}</string>
</dict>
</plist>
''';

  String _xml(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');
}
