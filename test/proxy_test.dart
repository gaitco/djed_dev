import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:djed_dev/djed_dev.dart';
import 'package:test/test.dart';

final fixture = p.absolute('test', 'fixtures', 'fake_app');

void main() {
  late Directory home;
  late AppRunner runner;
  late ProxyServer proxy;
  late HttpServer server;
  late HttpClient client;

  setUp(() async {
    home = Directory.systemTemp.createTempSync('djed_proxy');
    Directory(p.join(home.path, 'logs')).createSync();
    runner = AppRunner(
      tld: 'test',
      logs: Directory(p.join(home.path, 'logs')),
      pollInterval: const Duration(milliseconds: 100),
    );
    proxy = ProxyServer(
      sites: SiteRegistry(
        DjedConfig(links: {'fake': fixture, 'gone': '/nonexistent'}),
      ),
      runner: runner,
    );
    server = await proxy.listen(InternetAddress.loopbackIPv4, 0);
    client = HttpClient();
  });
  tearDown(() async {
    client.close(force: true);
    await proxy.close();
    await runner.stopAll();
    home.deleteSync(recursive: true);
  });

  Future<HttpClientResponse> send(
    String method,
    String host,
    String path, {
    String? body,
    Map<String, String> headers = const {},
  }) async {
    final request = await client.openUrl(
      method,
      Uri.parse('http://127.0.0.1:${server.port}$path'),
    );
    request.headers.set('host', host);
    headers.forEach(request.headers.set);
    if (body != null) request.write(body);
    return request.close();
  }

  Future<Map<String, Object?>> json(HttpClientResponse r) async =>
      jsonDecode(await utf8.decoder.bind(r).join()) as Map<String, Object?>;

  test(
    'forwards method, path, query, body, headers and adds X-Forwarded-*',
    () async {
      final response = await send(
        'POST',
        'fake.test',
        '/items?x=1&y=2',
        body: 'hello',
        headers: {'x-custom': 'c'},
      );
      expect(response.statusCode, 200);
      expect(response.headers.value('x-app'), 'fake');
      final data = await json(response);
      expect(data['method'], 'POST');
      expect(data['path'], '/items');
      expect(data['query'], {'x': '1', 'y': '2'});
      expect(data['body'], 'hello');
      expect(data['host'], 'fake.test');
      expect(data['forwardedProto'], 'http');
      expect(data['forwardedFor'], '127.0.0.1');
    },
  );

  test(
    'an inbound X-Forwarded-Proto cannot make a request look secure',
    () async {
      // dart:io derives request.requestedUri's scheme from these headers,
      // so trusting them let a plaintext request present itself to the app
      // as https - and as coming from any address it liked.
      final response = await send(
        'GET',
        'fake.test',
        '/',
        headers: {
          'x-forwarded-proto': 'https',
          'x-forwarded-for': '10.0.0.9',
          'x-forwarded-host': 'bank.test',
        },
      );
      final data = await json(response);
      expect(data['forwardedProto'], 'http');
      expect(data['forwardedFor'], '127.0.0.1');
      expect(data['host'], 'fake.test');
    },
  );

  test('an open websocket keeps the app out of the idle sweep', () async {
    final ws = await WebSocket.connect(
      'ws://127.0.0.1:${server.port}/ws',
      headers: {'host': 'fake.test'},
    );
    await ws.first;
    await runner.stopIdle(DateTime.now().add(const Duration(hours: 1)));
    expect(runner.status().length, 1, reason: 'the socket is still open');
    await ws.close();
    // The tunnel's two pipes settle a tick after the socket closes.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await runner.stopIdle(DateTime.now().add(const Duration(hours: 1)));
    expect(runner.status(), isEmpty);
  });

  test('subdomains reach the parent site', () async {
    final response = await send('GET', 'api.fake.test', '/');
    expect(response.statusCode, 200);
    expect((await json(response))['host'], 'api.fake.test');
  });

  test('unknown host is a 404 page listing sites', () async {
    final response = await send('GET', 'nope.test', '/');
    expect(response.statusCode, 404);
    final html = await utf8.decoder.bind(response).join();
    expect(html, contains('nope.test'));
    expect(html, contains('fake.test'));
    expect(response.headers.contentType?.mimeType, 'text/html');
  });

  test(
    'a site whose app cannot start is a 502 page with the log tail',
    () async {
      final response = await send('GET', 'gone.test', '/');
      expect(response.statusCode, 502);
      final html = await utf8.decoder.bind(response).join();
      expect(html, contains('gone.test'));
      expect(html.toLowerCase(), contains('exited'));
    },
  );

  test('websocket upgrade is tunnelled', () async {
    final ws = await WebSocket.connect(
      'ws://127.0.0.1:${server.port}/ws',
      headers: {'host': 'fake.test'},
    );
    // The fixture sends an 'hdr:...' message first, then echoes.
    final messages = ws.take(2).toList();
    ws.add('ping');
    expect((await messages)[1], 'echo:ping');
    await ws.close();
  });

  test('the tunnel forwards x-forwarded-for and x-forwarded-host', () async {
    final ws = await WebSocket.connect(
      'ws://127.0.0.1:${server.port}/ws',
      headers: {'host': 'fake.test'},
    );
    expect(await ws.first, 'hdr:fake.test:127.0.0.1');
    await ws.close();
  });

  test('a dead app reached via websocket upgrade is a 502, and the server '
      'keeps serving', () async {
    Object? error;
    try {
      await WebSocket.connect(
        'ws://127.0.0.1:${server.port}/ws',
        headers: {'host': 'gone.test'},
      );
    } catch (e) {
      error = e;
    }
    expect(error, isNotNull);
    final response = await send('GET', 'fake.test', '/');
    expect(response.statusCode, 200);
  });

  test('a crashed app is restarted on the next request', () async {
    final first = await json(await send('GET', 'fake.test', '/'));
    try {
      await send('GET', 'fake.test', '/crash');
    } catch (_) {
      // the app exits mid-response
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final second = await json(await send('GET', 'fake.test', '/'));
    expect(second['pid'], isNot(first['pid']));
  });

  test('a POST body after a crash reaches the restarted app intact', () async {
    try {
      await send('GET', 'fake.test', '/crash');
    } catch (_) {
      // the app exits mid-response
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final response = await send(
      'POST',
      'fake.test',
      '/',
      body: 'restarted-body',
    );
    final data = await json(response);
    expect(data['body'], 'restarted-body');
  });

  test('html escaping in error pages', () {
    expect(escapeHtml('<b>&"\''), '&lt;b&gt;&amp;&quot;&#39;');
    expect(notFoundPage('<x>.test', const [], 'test'), isNot(contains('<x>')));
  });

  /// Raw bytes, because `HttpClient` will not let a caller set
  /// `Connection` — and the exact bytes are the point.
  Future<String> raw(String request) async {
    final socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      server.port,
    );
    socket.write(request);
    await socket.flush();
    final reply = await utf8.decoder
        .bind(socket)
        .join()
        .timeout(const Duration(seconds: 20));
    await socket.close();
    return reply;
  }

  test('a POST marked Connection: upgrade keeps its body', () async {
    // What Herd's nginx sends in front of every request: `Connection:
    // upgrade` with no Upgrade header at all. dart:io then delivers no
    // body, so forwarding it as HTTP would throw and the caller would
    // see a 502 instead of their form being saved.
    const body = 'title=Recovered';
    final reply = await raw(
      'POST /items HTTP/1.1\r\n'
      'Host: fake.test\r\n'
      'Connection: upgrade\r\n'
      'Content-Type: application/x-www-form-urlencoded\r\n'
      'Content-Length: ${body.length}\r\n'
      '\r\n$body',
    );
    expect(reply, startsWith('HTTP/1.1 200'));
    expect(reply, contains('"body":"$body"'));
    expect(reply, contains('x-app: fake'));
  });

  test('an upgrade-marked request still gets X-Forwarded-*', () async {
    final reply = await raw(
      'GET /items HTTP/1.1\r\n'
      'Host: fake.test\r\n'
      'Connection: keep-alive, Upgrade\r\n'
      'Content-Length: 0\r\n'
      '\r\n',
    );
    expect(reply, contains('"host":"fake.test"'));
    expect(reply, contains('"forwardedProto":"http"'));
    expect(reply, contains('"forwardedFor":"127.0.0.1"'));
  });

  group('trustForwardedHeaders', () {
    setUp(() {
      // Herd keeps 443 and forwards to djed on a high port. Only then is
      // an inbound X-Forwarded-Proto authoritative, so the behaviour is
      // opt-in — the default stays the one the test above pins.
      proxy.sites = SiteRegistry(
        DjedConfig(links: {'fake': fixture}, trustForwardedHeaders: true),
      );
    });

    test("a front proxy's scheme and host survive the hop", () async {
      final data = await json(
        await send(
          'GET',
          'fake.test',
          '/items',
          headers: {
            'x-forwarded-proto': 'https',
            'x-forwarded-host': 'todo.test',
          },
        ),
      );
      expect(data['forwardedProto'], 'https');
    });

    test('without one, djed still declares its own scheme', () async {
      final data = await json(await send('GET', 'fake.test', '/items'));
      expect(data['forwardedProto'], 'http');
    });

    test('a nonsense scheme is refused even when trusting', () async {
      final data = await json(
        await send(
          'GET',
          'fake.test',
          '/items',
          headers: {'x-forwarded-proto': 'javascript'},
        ),
      );
      expect(data['forwardedProto'], 'http');
    });
  });
}
