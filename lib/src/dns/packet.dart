import 'dart:typed_data';

const dnsTypeA = 1;
const dnsTypeAAAA = 28;
const rcodeNoError = 0;
const rcodeRefused = 5;

/// The first question of a DNS query (all a stub resolver ever sends).
class DnsQuery {
  DnsQuery({
    required this.id,
    required this.name,
    required this.type,
    required this.klass,
    required this.recursionDesired,
    required this.questionBytes,
  });

  final int id;
  final String name;
  final int type;
  final int klass;
  final bool recursionDesired;

  /// The raw question section, echoed back verbatim in the response.
  final Uint8List questionBytes;

  /// Throws [FormatException] on anything shorter or stranger than a
  /// well-formed single-question query.
  static DnsQuery decode(Uint8List bytes) {
    if (bytes.length < 12) throw const FormatException('DNS packet too short');
    final data = ByteData.sublistView(bytes);
    final id = data.getUint16(0);
    final flags = data.getUint16(2);
    final questions = data.getUint16(4);
    if (questions < 1) {
      throw const FormatException('DNS packet has no question');
    }
    var offset = 12;
    final (name, end) = readName(bytes, offset);
    offset = end;
    if (offset + 4 > bytes.length) {
      throw const FormatException('DNS question truncated');
    }
    final type = data.getUint16(offset);
    final klass = data.getUint16(offset + 2);
    return DnsQuery(
      id: id,
      name: name,
      type: type,
      klass: klass,
      recursionDesired: flags & 0x0100 != 0,
      questionBytes: Uint8List.sublistView(bytes, 12, offset + 4),
    );
  }

  /// Reads a DNS name (label sequence) starting at [start], following any
  /// compression pointers -- which, per RFC 1035 4.1.4, must always point
  /// backward to a prior offset in the message. Returns the decoded name
  /// and the offset just past it in the *uncompressed* stream. Exposed
  /// (rather than kept private) so a name can be decoded from any offset,
  /// not just the question at byte 12 -- e.g. to test compression pointers
  /// directly.
  static (String, int) readName(Uint8List bytes, int start) {
    final labels = <String>[];
    var offset = start;
    int? endAfterPointer;
    var hops = 0;
    while (true) {
      if (offset >= bytes.length) {
        throw const FormatException('DNS name truncated');
      }
      final length = bytes[offset];
      if (length == 0) {
        offset++;
        break;
      }
      if (length & 0xc0 == 0xc0) {
        if (offset + 1 >= bytes.length) {
          throw const FormatException('DNS pointer truncated');
        }
        final pointer = ((length & 0x3f) << 8) | bytes[offset + 1];
        endAfterPointer ??= offset + 2;
        if (pointer >= offset || ++hops > 16) {
          throw const FormatException('DNS pointer loop');
        }
        offset = pointer;
        continue;
      }
      if (offset + 1 + length > bytes.length) {
        throw const FormatException('DNS label truncated');
      }
      labels.add(String.fromCharCodes(bytes, offset + 1, offset + 1 + length));
      offset += 1 + length;
    }
    return (labels.join('.').toLowerCase(), endAfterPointer ?? offset);
  }
}

class DnsAnswer {
  const DnsAnswer(this.type, this.ttl, this.rdata);
  final int type;
  final int ttl;
  final List<int> rdata;
}

/// A response to [query]: header with QR set, the question echoed, then
/// [answers] naming the question via a pointer to offset 12.
Uint8List encodeResponse(
  DnsQuery query, {
  required int rcode,
  required List<DnsAnswer> answers,
}) {
  final out = BytesBuilder();
  final flags = 0x8000 | (query.recursionDesired ? 0x0100 : 0) | (rcode & 0x0f);
  out
    ..add(_u16(query.id))
    ..add(_u16(flags))
    ..add(_u16(1))
    ..add(_u16(answers.length))
    ..add(_u16(0))
    ..add(_u16(0))
    ..add(query.questionBytes);
  for (final a in answers) {
    out
      ..add([0xc0, 0x0c])
      ..add(_u16(a.type))
      ..add(_u16(1))
      ..add([
        (a.ttl >> 24) & 0xff,
        (a.ttl >> 16) & 0xff,
        (a.ttl >> 8) & 0xff,
        a.ttl & 0xff,
      ])
      ..add(_u16(a.rdata.length))
      ..add(a.rdata);
  }
  return out.toBytes();
}

List<int> _u16(int v) => [(v >> 8) & 0xff, v & 0xff];

/// The policy: names under [tld] get `127.0.0.1` / `::1`, anything else
/// is REFUSED, malformed input gets no reply (`null`).
Uint8List? respondTo(Uint8List packet, String tld) {
  final DnsQuery query;
  try {
    query = DnsQuery.decode(packet);
  } on FormatException {
    return null;
  }
  final inTld = query.name == tld || query.name.endsWith('.$tld');
  if (!inTld) {
    return encodeResponse(query, rcode: rcodeRefused, answers: const []);
  }
  final answers = switch (query.type) {
    dnsTypeA => [
      const DnsAnswer(dnsTypeA, 60, [127, 0, 0, 1]),
    ],
    dnsTypeAAAA => [
      DnsAnswer(dnsTypeAAAA, 60, [...List.filled(15, 0), 1]),
    ],
    _ => const <DnsAnswer>[],
  };
  return encodeResponse(query, rcode: rcodeNoError, answers: answers);
}
