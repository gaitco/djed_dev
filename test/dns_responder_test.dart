import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:djed_dev/djed_dev.dart';
import 'package:test/test.dart';

Uint8List query(String name, int type) {
  final bytes = <int>[0xab, 0xcd, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0];
  for (final label in name.split('.')) {
    bytes
      ..add(label.length)
      ..addAll(label.codeUnits);
  }
  bytes.addAll([0, type >> 8, type & 0xff, 0, 1]);
  return Uint8List.fromList(bytes);
}

void main() {
  late DnsResponder responder;
  setUp(() async {
    responder = DnsResponder(tld: 'test', port: 0);
    await responder.start();
  });
  tearDown(() => responder.stop());

  // Reads the reply inside the listener itself: `.first` would cancel the
  // subscription on match, and that cancellation discards the datagram
  // buffered by RawDatagramSocket before `receive()` gets a chance to read it.
  Future<Uint8List> ask(String name, int type) async {
    final socket = await RawDatagramSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final reply = Completer<Uint8List>();
    final subscription = socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      final datagram = socket.receive();
      if (datagram != null && !reply.isCompleted) reply.complete(datagram.data);
    });
    socket.send(
      query(name, type),
      InternetAddress.loopbackIPv4,
      responder.boundPort,
    );
    try {
      return await reply.future.timeout(const Duration(seconds: 2));
    } finally {
      await subscription.cancel();
      socket.close();
    }
  }

  test('answers A and AAAA for the tld', () async {
    final a = await ask('blog.test', dnsTypeA);
    expect(a[0], 0xab);
    expect(a.sublist(a.length - 4), [127, 0, 0, 1]);
    final aaaa = await ask('deep.blog.test', dnsTypeAAAA);
    expect(aaaa.sublist(aaaa.length - 16), [...List.filled(15, 0), 1]);
  });

  test('refuses other names', () async {
    final r = await ask('example.com', dnsTypeA);
    expect(r[3] & 0x0f, rcodeRefused);
  });

  test('ignores garbage without dying', () async {
    final socket = await RawDatagramSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    socket.send(
      Uint8List.fromList([1, 2, 3]),
      InternetAddress.loopbackIPv4,
      responder.boundPort,
    );
    socket.close();
    final r = await ask('blog.test', dnsTypeA);
    expect(r.sublist(r.length - 4), [127, 0, 0, 1]);
  });
}
