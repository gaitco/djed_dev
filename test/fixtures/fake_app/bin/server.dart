// A stand-in for a Maat app: honours APP_HOST/APP_PORT, echoes what it
// received, supports WebSocket echo at /ws, exits 1 when FAIL=1, and
// ignores SIGTERM (so only SIGKILL ends it) when IGNORE_SIGTERM=1.
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  final env = Platform.environment;
  if (env['FAIL'] == '1') {
    stderr.writeln('fake_app: refusing to start');
    exit(1);
  }
  if (env['IGNORE_SIGTERM'] == '1') {
    ProcessSignal.sigterm.watch().listen((_) {});
  }
  if (env['SLOW'] == '1') {
    await Future<void>.delayed(const Duration(seconds: 3));
  }
  final server = await HttpServer.bind(
    env['APP_HOST'] ?? '127.0.0.1',
    int.parse(env['APP_PORT'] ?? '0'),
  );
  stdout.writeln('fake_app listening on ${server.port} url=${env['APP_URL']}');
  await for (final request in server) {
    if (request.uri.path == '/ws' &&
        WebSocketTransformer.isUpgradeRequest(request)) {
      final forwardedHost = request.headers.value('x-forwarded-host');
      final forwardedFor = request.headers.value('x-forwarded-for');
      final socket = await WebSocketTransformer.upgrade(request);
      socket.add('hdr:$forwardedHost:$forwardedFor');
      socket.listen((m) => socket.add('echo:$m'), onDone: socket.close);
      continue;
    }
    if (request.uri.path == '/crash') exit(3);
    final body = await utf8.decoder.bind(request).join();
    request.response
      ..headers.contentType = ContentType.json
      ..headers.set('x-app', 'fake')
      ..write(
        jsonEncode({
          'method': request.method,
          'path': request.uri.path,
          'query': request.uri.queryParameters,
          'body': body,
          'host': request.headers.value('host'),
          'forwardedProto': request.headers.value('x-forwarded-proto'),
          'forwardedFor': request.headers.value('x-forwarded-for'),
          'pid': pid,
        }),
      );
    await request.response.close();
  }
}
