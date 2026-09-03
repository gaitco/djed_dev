import 'dart:async';
import 'dart:io';

import 'packet.dart';

/// UDP server answering `*.<tld>` with the loopback address. Only what
/// `/etc/resolver/<tld>` forwards ever reaches it.
class DnsResponder {
  DnsResponder({
    required this.tld,
    this.port = 53535,
    InternetAddress? address,
    this.onError,
  }) : address = address ?? InternetAddress.loopbackIPv4;

  final String tld;
  final int port;
  final InternetAddress address;
  final void Function(Object error)? onError;

  RawDatagramSocket? _socket;
  StreamSubscription<RawSocketEvent>? _subscription;

  /// The bound port (differs from [port] when it was 0).
  int get boundPort => _socket?.port ?? port;

  Future<void> start() async {
    final socket = await RawDatagramSocket.bind(address, port);
    _socket = socket;
    _subscription = socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      final datagram = socket.receive();
      if (datagram == null) return;
      try {
        final reply = respondTo(datagram.data, tld);
        if (reply != null) socket.send(reply, datagram.address, datagram.port);
      } catch (e) {
        onError?.call(e);
      }
    });
  }

  Future<void> stop() async {
    await _subscription?.cancel();
    _socket?.close();
    _socket = null;
  }
}
