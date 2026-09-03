import 'dart:io';

import 'package:path/path.dart' as p;

import '../config.dart';

class OpensslFailed implements Exception {
  OpensslFailed(this.message);
  final String message;
  @override
  String toString() => 'OpensslFailed: $message';
}

/// A file djed owns could not be given the mode it needs. Deliberately
/// not an [OpensslFailed]: the two are fixed in completely different
/// ways, and telling someone to install OpenSSL because a `chmod` was
/// denied sends them nowhere.
class PermissionsFailed implements Exception {
  PermissionsFailed(this.message);
  final String message;
  @override
  String toString() => 'PermissionsFailed: $message';
}

/// A local CA and one leaf listing every site by name, made with the
/// system `openssl`. Trusting the CA is the platform layer's job.
///
/// A single `*.<tld>` wildcard SAN looks appealing but fails strict
/// hostname verification (curl/OpenSSL and Dart's own TLS stack refuse a
/// wildcard pattern with fewer than two dots, which a single-label tld
/// like `test` can never have): so the leaf instead lists each site
/// explicitly, plus a per-site wildcard for its own subdomains.
class Certificates {
  /// [openssl] defaults to `DJED_OPENSSL` (which `install` puts in the
  /// launchd plist) and then to the PATH, so the daemon uses the same
  /// binary `install` resolved rather than whatever launchd's own
  /// `/usr/bin:/bin:/usr/sbin:/sbin` turns up.
  Certificates(this.paths, {String? openssl})
    : openssl = openssl ?? Platform.environment['DJED_OPENSSL'] ?? 'openssl';

  final DjedPaths paths;
  final String openssl;

  static const caDays = 3650;
  static const leafDays = 825;

  bool get caExists => paths.caKey.existsSync() && paths.caCert.existsSync();
  bool get leafExists =>
      paths.leafKey.existsSync() && paths.leafCert.existsSync();

  Future<void> ensureCa() async {
    if (caExists) {
      // Also repair a CA generated before the permissions were enforced.
      await _restrictCa();
      return;
    }
    paths.ensureDirectories();
    await _run([
      'req',
      '-x509',
      '-newkey',
      'rsa:2048',
      '-nodes',
      '-sha256',
      '-days',
      '$caDays',
      '-subj',
      '/CN=djed local CA/O=djed',
      '-addext',
      'basicConstraints=critical,CA:TRUE',
      '-addext',
      'keyUsage=critical,keyCertSign,cRLSign',
      '-keyout',
      paths.caKey.path,
      '-out',
      paths.caCert.path,
    ]);
    await _restrictCa();
  }

  /// The CA key signs a root the System keychain trusts unconditionally:
  /// anyone who can read it can forge a certificate for any host. Some
  /// openssl builds (LibreSSL, which is what `/usr/bin/openssl` is on
  /// macOS) write it 0644 under the default umask.
  Future<void> _restrictCa() async {
    await _restrict(paths.caKey.parent.path, '700');
    await _restrict(paths.caKey.path, '600');
  }

  /// Dart has no `chmod`; shelling out is the only way to take the group
  /// and other bits off a file openssl already wrote.
  Future<void> _restrict(String path, String mode) async {
    final result = await Process.run('/bin/chmod', [mode, path]);
    if (result.exitCode != 0) {
      throw PermissionsFailed('chmod $mode $path failed: ${result.stderr}');
    }
  }

  /// The SANs a leaf for [tld]/[sites] must carry: `localhost`, the
  /// loopback IP and the bare tld always; then, for each site (deduped,
  /// sorted for a deterministic, comparable order), its exact name and its
  /// own wildcard subdomain.
  static List<String> sansFor(String tld, List<String> sites) => [
    'DNS:localhost',
    'IP:127.0.0.1',
    'DNS:$tld',
    for (final s in sites.toSet().toList()..sort()) ...[
      'DNS:$s.$tld',
      'DNS:*.$s.$tld',
    ],
  ];

  /// openssl's human-readable SAN text spells the IP entry `IP
  /// Address:127.0.0.1`; normalize to the `IP:127.0.0.1` form used when
  /// writing the extension file, so the two are comparable.
  static String _normalizeSan(String san) => san.startsWith('IP Address:')
      ? 'IP:${san.substring('IP Address:'.length)}'
      : san;

  /// Ensures a leaf exists whose SANs are exactly [sansFor] `(tld,
  /// sites)`. Regenerates when [force] is set, no leaf exists yet, or the
  /// current leaf's SAN set (as a set - order doesn't matter) differs from
  /// what's wanted; returns whether it regenerated the leaf.
  Future<bool> ensureLeaf(
    String tld, {
    List<String> sites = const [],
    bool force = false,
  }) async {
    final wanted = sansFor(tld, sites);
    if (leafExists && !force) {
      final current = (await leafSans()).map(_normalizeSan).toSet();
      final wantedNormalized = wanted.map(_normalizeSan).toSet();
      if (current.containsAll(wantedNormalized) &&
          current.length == wantedNormalized.length) {
        return false;
      }
    }
    if (!caExists) await ensureCa();
    paths.ensureDirectories();
    final tmp = Directory.systemTemp.createTempSync('djed_leaf');
    try {
      final csr = p.join(tmp.path, 'leaf.csr');
      final ext = File(p.join(tmp.path, 'leaf.ext'))
        ..writeAsStringSync(
          'subjectAltName = ${wanted.join(', ')}\n'
          'extendedKeyUsage = serverAuth\n'
          'basicConstraints = CA:FALSE\n',
        );
      await _run([
        'req',
        '-new',
        '-newkey',
        'rsa:2048',
        '-nodes',
        '-sha256',
        '-subj',
        '/CN=$tld/O=djed',
        '-keyout',
        paths.leafKey.path,
        '-out',
        csr,
      ]);
      await _run([
        'x509',
        '-req',
        '-sha256',
        '-days',
        '$leafDays',
        '-in',
        csr,
        '-CA',
        paths.caCert.path,
        '-CAkey',
        paths.caKey.path,
        '-CAcreateserial',
        '-extfile',
        ext.path,
        '-out',
        paths.leafCert.path,
      ]);
      await _restrict(paths.leafKey.path, '600');
    } finally {
      tmp.deleteSync(recursive: true);
    }
    return true;
  }

  Future<DateTime?> leafExpiry() async {
    if (!leafExists) return null;
    final out = await _run([
      'x509',
      '-in',
      paths.leafCert.path,
      '-noout',
      '-enddate',
    ]);
    // notAfter=Dec  5 10:00:00 2028 GMT
    final text = out.trim().split('=').last.replaceAll(RegExp(r'\s+'), ' ');
    final m = RegExp(
      r'^(\w{3}) (\d+) (\d+):(\d+):(\d+) (\d{4}) GMT$',
    ).firstMatch(text);
    if (m == null) return null;
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return DateTime.utc(
      int.parse(m[6]!),
      months.indexOf(m[1]!) + 1,
      int.parse(m[2]!),
      int.parse(m[3]!),
      int.parse(m[4]!),
      int.parse(m[5]!),
    );
  }

  Future<bool> leafExpiresWithin(Duration window) async {
    final expiry = await leafExpiry();
    return expiry == null || expiry.isBefore(DateTime.now().add(window));
  }

  /// The leaf's SANs, in openssl's own `DNS:`/`IP Address:` spelling.
  ///
  /// Read from `-text` rather than the tidier `-ext subjectAltName`:
  /// LibreSSL has no `-ext` flag at all, and LibreSSL is what
  /// `/usr/bin/openssl` is on macOS — the daemon would crash-loop the
  /// moment it resolved that one. Both implementations print the whole
  /// SAN list, however long, on the single line below the extension's
  /// header.
  Future<List<String>> leafSans() async {
    final out = await _run([
      'x509',
      '-in',
      paths.leafCert.path,
      '-noout',
      '-text',
    ]);
    final lines = out.split('\n');
    final header = lines.indexWhere(
      (l) => l.contains('X509v3 Subject Alternative Name:'),
    );
    if (header < 0 || header + 1 >= lines.length) return const [];
    return lines[header + 1]
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
  }

  SecurityContext securityContext() => SecurityContext()
    ..useCertificateChain(paths.leafCert.path)
    ..usePrivateKey(paths.leafKey.path);

  Future<String> _run(List<String> args) async {
    final ProcessResult result;
    try {
      result = await Process.run(openssl, args);
    } on ProcessException catch (e) {
      throw OpensslFailed('cannot run $openssl: ${e.message}');
    }
    if (result.exitCode != 0) {
      final stderr = result.stderr.toString();
      // openssl cannot open a key root wrote: telling the user to install
      // OpenSSL sends them nowhere.
      if (stderr.toLowerCase().contains('permission denied')) {
        throw PermissionsFailed('openssl ${args.first} failed: $stderr');
      }
      throw OpensslFailed('openssl ${args.first} failed: $stderr');
    }
    return result.stdout.toString();
  }
}
