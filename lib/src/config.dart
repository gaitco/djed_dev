import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Every file djed owns, under one home directory
/// (`$DJED_HOME` or `~/.config/djed`).
class DjedPaths {
  DjedPaths(this.home);

  /// Resolves the home from [environment] (defaults to the process
  /// environment).
  factory DjedPaths.resolve([Map<String, String>? environment]) {
    final env = environment ?? Platform.environment;
    final home =
        env['DJED_HOME'] ??
        p.join(env['HOME'] ?? Directory.current.path, '.config', 'djed');
    return DjedPaths(Directory(home));
  }

  final Directory home;

  File get config => File(p.join(home.path, 'config.json'));
  File get caKey => File(p.join(home.path, 'ca', 'ca.key'));
  File get caCert => File(p.join(home.path, 'ca', 'ca.pem'));
  File get leafKey => File(p.join(home.path, 'certs', 'test.key'));
  File get leafCert => File(p.join(home.path, 'certs', 'test.pem'));
  Directory get logs => Directory(p.join(home.path, 'logs'));
  File get daemonLog => File(p.join(logs.path, 'daemon.log'));
  File siteLog(String site) => File(p.join(logs.path, '$site.log'));
  File get pidFile => File(p.join(home.path, 'daemon.pid'));
  File get socket => File(p.join(home.path, 'daemon.sock'));

  void ensureDirectories() {
    for (final d in [home, caKey.parent, leafKey.parent, logs]) {
      d.createSync(recursive: true);
    }
  }
}

final _tldPattern = RegExp(r'^[a-z0-9]([a-z0-9-]*[a-z0-9])?$');

/// The Dart VM this process happens to be running on, or a bare `dart`
/// when there is none to point at.
///
/// [Platform.resolvedExecutable] is the VM only while djed itself runs
/// on it. A `dart compile exe` binary reports *its own* path, so a
/// command built from it asks `djed` to `run bin/server.dart`, which
/// exits 64 before the app ever listens. That is why `install` resolves
/// and pins the answer rather than leaving it to whatever started the
/// daemon.
String defaultDartExecutable() {
  final exe = Platform.resolvedExecutable;
  return p.basenameWithoutExtension(exe) == 'dart' ? exe : 'dart';
}

/// `config.json`: parked paths, links and ports. Immutable; use
/// [copyWith] and [save].
class DjedConfig {
  DjedConfig({
    this.tld = 'test',
    List<String> paths = const [],
    Map<String, String> links = const {},
    this.idleMinutes = 15,
    this.dnsPort = 53535,
    this.httpPort = 80,
    this.httpsPort = 443,
    this.startTimeoutSeconds = 60,
    this.trustForwardedHeaders = false,
    String? openssl,
    String? dart,
  }) : paths = List.unmodifiable(paths),
       links = Map.unmodifiable(links),
       // `install` records the absolute path it resolved; a config
       // written before that (or by hand) falls back to what launchd's
       // plist exports, then to the PATH.
       openssl = openssl ?? Platform.environment['DJED_OPENSSL'] ?? 'openssl',
       // Same chain for the VM that runs the applications. Unlike
       // `openssl` this one is honoured even as root: apps are spawned
       // behind `sudo -u <user>`, so the binary named here runs with the
       // user's privileges, which they had anyway.
       dart =
           dart ??
           Platform.environment['DJED_DART'] ??
           defaultDartExecutable() {
    if (!_tldPattern.hasMatch(tld)) {
      throw FormatException(
        "Invalid tld '$tld': letters, digits and dashes only",
      );
    }
  }

  factory DjedConfig.fromJson(Map<String, Object?> json) => DjedConfig(
    tld: json['tld'] as String? ?? 'test',
    paths: (json['paths'] as List?)?.cast<String>() ?? const [],
    links: (json['links'] as Map?)?.cast<String, String>() ?? const {},
    idleMinutes: json['idleMinutes'] as int? ?? 15,
    dnsPort: json['dnsPort'] as int? ?? 53535,
    httpPort: json['httpPort'] as int? ?? 80,
    httpsPort: json['httpsPort'] as int? ?? 443,
    startTimeoutSeconds: json['startTimeoutSeconds'] as int? ?? 60,
    trustForwardedHeaders: json['trustForwardedHeaders'] as bool? ?? false,
    openssl: json['openssl'] as String?,
    dart: json['dart'] as String?,
  );

  final String tld;
  final List<String> paths;
  final Map<String, String> links;
  final int idleMinutes;
  final int dnsPort;
  final int httpPort;
  final int httpsPort;
  final int startTimeoutSeconds;

  /// Whether an inbound `X-Forwarded-*` header may be believed.
  ///
  /// False by default, and that default is a security property: when djed
  /// is the front door any client can set the header, and trusting it lets
  /// a plaintext request present itself to the app as HTTPS from any
  /// address it likes. Turn it on only when something else — Herd, nginx, a
  /// load balancer — owns the public port and djed never sees a client
  /// directly.
  final bool trustForwardedHeaders;

  /// The `openssl` binary certificates are generated and read with.
  final String openssl;

  /// The `dart` binary applications are started with.
  final String dart;

  String url(String site) => 'https://$site.$tld';

  Map<String, Object?> toJson() => {
    'tld': tld,
    'paths': paths,
    'links': links,
    'idleMinutes': idleMinutes,
    'dnsPort': dnsPort,
    'httpPort': httpPort,
    'httpsPort': httpsPort,
    'startTimeoutSeconds': startTimeoutSeconds,
    'trustForwardedHeaders': trustForwardedHeaders,
    'openssl': openssl,
    'dart': dart,
  };

  DjedConfig copyWith({
    String? tld,
    List<String>? paths,
    Map<String, String>? links,
    int? idleMinutes,
    int? dnsPort,
    int? httpPort,
    int? httpsPort,
    int? startTimeoutSeconds,
    bool? trustForwardedHeaders,
    String? openssl,
    String? dart,
  }) => DjedConfig(
    tld: tld ?? this.tld,
    paths: paths ?? this.paths,
    links: links ?? this.links,
    idleMinutes: idleMinutes ?? this.idleMinutes,
    dnsPort: dnsPort ?? this.dnsPort,
    httpPort: httpPort ?? this.httpPort,
    httpsPort: httpsPort ?? this.httpsPort,
    startTimeoutSeconds: startTimeoutSeconds ?? this.startTimeoutSeconds,
    trustForwardedHeaders: trustForwardedHeaders ?? this.trustForwardedHeaders,
    openssl: openssl ?? this.openssl,
    dart: dart ?? this.dart,
  );

  /// Defaults when the file does not exist; [FormatException] when it is
  /// not valid JSON.
  static Future<DjedConfig> load(DjedPaths paths) async {
    if (!paths.config.existsSync()) return DjedConfig();
    final decoded = jsonDecode(await paths.config.readAsString());
    if (decoded is! Map) {
      throw FormatException('${paths.config.path} is not a JSON object');
    }
    return DjedConfig.fromJson(decoded.cast<String, Object?>());
  }

  Future<void> save(DjedPaths paths) async {
    paths.ensureDirectories();
    await paths.config.writeAsString(
      const JsonEncoder.withIndent('  ').convert(toJson()),
    );
  }
}
