import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// JSON-lines over a Unix socket: one request object, one response object.
class ControlClient {
  ControlClient(this.socketFile);

  final File socketFile;

  Future<bool> get alive async {
    try {
      final r = await send({
        'cmd': 'status',
      }).timeout(const Duration(seconds: 2));
      return r['pid'] != null;
    } catch (_) {
      return false;
    }
  }

  /// Connects, writes [command] and reads one reply line, all bounded by
  /// [timeout]: a daemon that accepts the connection but never replies (or
  /// never accepts it) must not hang the caller forever.
  Future<Map<String, Object?>> send(
    Map<String, Object?> command, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final socket = await Socket.connect(
      InternetAddress(socketFile.path, type: InternetAddressType.unix),
      0,
    ).timeout(timeout);
    try {
      socket.writeln(jsonEncode(command));
      await socket.flush();
      final line = await utf8.decoder
          .bind(socket)
          .transform(const LineSplitter())
          .first
          .timeout(
            timeout,
            onTimeout: () => throw TimeoutException(
              'djed: daemon did not respond within $timeout',
            ),
          );
      final decoded = jsonDecode(line) as Map<String, Object?>;
      if (decoded['error'] != null) {
        throw StateError(decoded['error'].toString());
      }
      return decoded;
    } finally {
      socket.destroy();
    }
  }
}

/// Renames [file] to `<file>.1` when it exceeds [maxBytes].
Future<void> rotateLog(File file, {int maxBytes = 5 * 1024 * 1024}) async {
  if (!file.existsSync() || file.lengthSync() <= maxBytes) return;
  final backup = File('${file.path}.1');
  if (backup.existsSync()) backup.deleteSync();
  await file.rename(backup.path);
}
