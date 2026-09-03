import 'dart:typed_data';

import 'package:djed_dev/djed_dev.dart';
import 'package:test/test.dart';

/// A query for [name] of [type] as a resolver would send it.
Uint8List query(String name, int type, {int id = 0x1234}) {
  final bytes = <int>[
    id >> 8, id & 0xff, 0x01, 0x00, // flags: RD
    0, 1, 0, 0, 0, 0, 0, 0,
  ];
  for (final label in name.split('.')) {
    bytes.add(label.length);
    bytes.addAll(label.codeUnits);
  }
  bytes.addAll([0, type >> 8, type & 0xff, 0, 1]);
  return Uint8List.fromList(bytes);
}

void main() {
  test('decodes id, name, type, class and RD', () {
    final q = DnsQuery.decode(query('blog.test', dnsTypeA));
    expect(q.id, 0x1234);
    expect(q.name, 'blog.test');
    expect(q.type, dnsTypeA);
    expect(q.klass, 1);
    expect(q.recursionDesired, isTrue);
  });

  test('response echoes the question and carries an A answer', () {
    final q = DnsQuery.decode(query('blog.test', dnsTypeA));
    final r = encodeResponse(
      q,
      rcode: rcodeNoError,
      answers: [
        DnsAnswer(dnsTypeA, 60, [127, 0, 0, 1]),
      ],
    );
    expect(r[0], 0x12);
    expect(r[1], 0x34);
    expect(r[2] & 0x80, 0x80, reason: 'QR bit');
    expect(r[3] & 0x0f, rcodeNoError);
    expect(r.sublist(4, 12), [0, 1, 0, 1, 0, 0, 0, 0]);
    final q2 = DnsQuery.decode(r);
    expect(q2.name, 'blog.test');
    // header(12) + echoed question: name(11) + type/class(4) = 27.
    final answer = r.sublist(12 + 15);
    expect(answer.sublist(0, 2), [0xc0, 0x0c], reason: 'name pointer');
    expect(answer.sublist(2, 4), [0, 1]);
    expect(answer.sublist(4, 6), [0, 1]);
    expect(answer.sublist(6, 10), [0, 0, 0, 60]);
    expect(answer.sublist(10, 12), [0, 4]);
    expect(answer.sublist(12), [127, 0, 0, 1]);
  });

  test('refused response has no answers', () {
    final q = DnsQuery.decode(query('x.local', dnsTypeA));
    final r = encodeResponse(q, rcode: rcodeRefused, answers: const []);
    expect(r[3] & 0x0f, rcodeRefused);
    expect(r.sublist(6, 8), [0, 0]);
  });

  test('a backward compression pointer is followed', () {
    // header(12) + [4 test 0](6, offset 12-17) + [4 blog 0xc0 12](7, offset
    // 18-24): the second name's pointer targets the first name's labels,
    // which sit *earlier* in the message -- the only direction RFC 1035
    // 4.1.4 allows. Uses the public DnsQuery.readName entry point since the
    // question DnsQuery.decode reads always starts at offset 12.
    final packet = query('blog.test', dnsTypeA);
    final withPointer = Uint8List.fromList([
      ...packet.sublist(0, 12),
      4,
      ...'test'.codeUnits,
      0,
      4,
      ...'blog'.codeUnits,
      0xc0,
      12,
    ]);
    final (name, end) = DnsQuery.readName(withPointer, 18);
    expect(name, 'blog.test');
    expect(end, 25);
  });

  test('a forward compression pointer is rejected', () {
    // Same shape as above but with the labels swapped, so the pointer at
    // offset 17 targets offset 19 -- forward, which RFC 1035 forbids.
    final packet = query('blog.test', dnsTypeA);
    final withForwardPointer = Uint8List.fromList([
      ...packet.sublist(0, 12),
      4,
      ...'blog'.codeUnits,
      0xc0,
      19,
      4,
      ...'test'.codeUnits,
      0,
    ]);
    expect(
      () => DnsQuery.readName(withForwardPointer, 12),
      throwsFormatException,
    );
  });

  test('truncated packets throw FormatException', () {
    expect(() => DnsQuery.decode(Uint8List(5)), throwsFormatException);
    expect(
      () => DnsQuery.decode(query('blog.test', dnsTypeA).sublist(0, 16)),
      throwsFormatException,
    );
  });

  test('respondTo answers only the tld', () {
    final a = respondTo(query('blog.test', dnsTypeA), 'test')!;
    expect(a.sublist(a.length - 4), [127, 0, 0, 1]);
    final aaaa = respondTo(query('blog.test', dnsTypeAAAA), 'test')!;
    expect(aaaa.sublist(aaaa.length - 16), [...List.filled(15, 0), 1]);
    final txt = respondTo(query('blog.test', 16), 'test')!;
    expect(txt[3] & 0x0f, rcodeNoError);
    expect(txt.sublist(6, 8), [0, 0]);
    final bare = respondTo(query('test', dnsTypeA), 'test')!;
    expect(bare.sublist(bare.length - 4), [127, 0, 0, 1]);
    final other = respondTo(query('blog.local', dnsTypeA), 'test')!;
    expect(other[3] & 0x0f, rcodeRefused);
    expect(respondTo(Uint8List(3), 'test'), isNull);
  });
}
