import 'dart:io';

/// A free loopback port: bind 0, read what the OS chose, release it.
Future<int> allocatePort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}
