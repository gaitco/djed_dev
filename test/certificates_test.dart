import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:djed_dev/djed_dev.dart';
import 'package:test/test.dart';

void main() {
  late Directory home;
  late DjedPaths paths;
  late Certificates certs;

  setUp(() {
    home = Directory.systemTemp.createTempSync('djed_certs');
    paths = DjedPaths(home)..ensureDirectories();
    certs = Certificates(paths);
  });
  tearDown(() => home.deleteSync(recursive: true));

  test('creates a CA and a leaf with per-site SANs', () async {
    expect(certs.caExists, isFalse);
    await certs.ensureCa();
    expect(certs.caExists, isTrue);
    await certs.ensureLeaf('test', sites: ['blog', 'shop']);
    expect(certs.leafExists, isTrue);
    expect(
      await certs.leafSans(),
      containsAll([
        'DNS:blog.test',
        'DNS:*.blog.test',
        'DNS:shop.test',
        'DNS:*.shop.test',
        'DNS:localhost',
        'DNS:test',
        'IP Address:127.0.0.1',
      ]),
    );
    expect(await certs.leafSans(), isNot(contains('DNS:*.test')));
    final expiry = await certs.leafExpiry();
    expect(
      expiry!.difference(DateTime.now()).inDays,
      inInclusiveRange(820, 826),
    );
    expect(await certs.leafExpiresWithin(const Duration(days: 30)), isFalse);
  });

  test('ensure* are idempotent unless forced', () async {
    await certs.ensureCa();
    await certs.ensureLeaf('test');
    final before = paths.leafCert.readAsBytesSync();
    await certs.ensureLeaf('test');
    expect(paths.leafCert.readAsBytesSync(), before);
    await certs.ensureLeaf('test', force: true);
    expect(paths.leafCert.readAsBytesSync(), isNot(before));
  });

  test('regenerates only when the site set changes', () async {
    await certs.ensureCa();
    expect(await certs.ensureLeaf('test', sites: ['a']), isTrue);
    final firstBytes = paths.leafCert.readAsBytesSync();
    expect(await certs.ensureLeaf('test', sites: ['a']), isFalse);
    expect(paths.leafCert.readAsBytesSync(), firstBytes);
    expect(await certs.ensureLeaf('test', sites: ['a', 'b']), isTrue);
    final secondBytes = paths.leafCert.readAsBytesSync();
    expect(secondBytes, isNot(firstBytes));
    expect(await certs.ensureLeaf('test', sites: ['b', 'a']), isFalse);
    expect(paths.leafCert.readAsBytesSync(), secondBytes);
  });

  test(
    'the leaf verifies against the CA and loads into a SecurityContext',
    () async {
      await certs.ensureCa();
      await certs.ensureLeaf('test');
      final verify = await Process.run('openssl', [
        'verify',
        '-CAfile',
        paths.caCert.path,
        paths.leafCert.path,
      ]);
      expect(verify.exitCode, 0, reason: verify.stderr.toString());
      final server = await HttpServer.bindSecure(
        InternetAddress.loopbackIPv4,
        0,
        certs.securityContext(),
      );
      server.listen((r) => r.response.close());
      final client = HttpClient(
        context: SecurityContext()..setTrustedCertificates(paths.caCert.path),
      );
      final response = await (await client.getUrl(
        Uri.parse('https://localhost:${server.port}/'),
      )).close();
      expect(response.statusCode, 200);
      client.close();
      await server.close();
    },
  );

  test('the private keys are readable only by their owner', () async {
    await certs.ensureCa();
    await certs.ensureLeaf('test');
    // A CA left world-readable by an earlier version is repaired too.
    await Process.run('chmod', ['644', paths.caKey.path]);
    await certs.ensureCa();
    // The CA key signs a root trusted in the System keychain: readable by
    // anyone is a certificate-forging primitive. LibreSSL (macOS's own
    // /usr/bin/openssl) writes 0644 under the default umask.
    for (final key in [paths.caKey, paths.leafKey]) {
      expect(
        key.statSync().mode & 0x1FF,
        0x180,
        reason: '${key.path} should be 0600',
      );
    }
    expect(paths.caKey.parent.statSync().mode & 0x1FF, 0x1C0);
  });

  test('leafSans reads SANs from an openssl without -ext', () async {
    // LibreSSL has no `x509 -ext`; the SANs must still come back in
    // openssl's own spelling.
    await certs.ensureCa();
    await certs.ensureLeaf('test', sites: ['blog']);
    final libre = Certificates(paths, openssl: '/usr/bin/openssl');
    expect(
      await libre.leafSans(),
      containsAll([
        'DNS:localhost',
        'IP Address:127.0.0.1',
        'DNS:test',
        'DNS:blog.test',
        'DNS:*.blog.test',
      ]),
    );
    // ...and comparing them against the wanted set must not regenerate.
    expect(await libre.ensureLeaf('test', sites: ['blog']), isFalse);
  });

  test('a missing openssl is a clear error', () async {
    final broken = Certificates(paths, openssl: '/nonexistent/openssl');
    expect(() => broken.ensureCa(), throwsA(isA<OpensslFailed>()));
  });

  test('an openssl that cannot read its key is a permissions error', () async {
    // What a root-owned ca.key looks like from the user's side. Not an
    // OpensslFailed: openssl is installed and working, the file is not
    // ours to read.
    final denying = File(p.join(paths.home.path, 'denying-ssl'))
      ..writeAsStringSync(
        '#!/bin/sh\necho "Could not open file: Permission denied" >&2\nexit 1\n',
      );
    await Process.run('/bin/chmod', ['700', denying.path]);
    expect(
      () => Certificates(paths, openssl: denying.path).ensureCa(),
      throwsA(isA<PermissionsFailed>()),
    );
  });
}
