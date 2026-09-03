import 'dart:async';
import 'dart:io';

import '../apps/app_runner.dart';
import '../sites.dart';
import 'error_page.dart';

/// Whatever a client sent under these names is a claim about a proxy hop
/// that did not happen: dart:io even derives `request.requestedUri` from
/// them, so an inbound `X-Forwarded-Proto: https` would otherwise reach
/// the app as proof the request was secure. They are dropped and set from
/// what this listener actually knows.
const _forwarded = {'x-forwarded-for', 'x-forwarded-proto', 'x-forwarded-host'};

/// The scheme to declare to the app.
///
/// [secure] is whether *this* listener terminated TLS, which is the right
/// answer only when djed is the front door. Behind another proxy — Herd
/// or nginx keeping 443 while djed serves a high port — the client spoke
/// HTTPS and only the last hop is plain, so overwriting the header the
/// front proxy set would make every absolute URL the app builds point back
/// at `http://`.
///
/// An incoming value is preserved only when `trustForwardedHeaders` says
/// something in front is authoritative. Left off — the default, and the
/// right one when djed owns 80 and 443 — any client could set the header
/// and make a plaintext request look secure to the app.
String _forwardedProto(HttpRequest request, bool secure, bool trust) {
  if (trust) {
    final claimed = request.headers
        .value('x-forwarded-proto')
        ?.split(',')
        .first
        .trim();
    if (claimed == 'http' || claimed == 'https') return claimed!;
  }
  return secure ? 'https' : 'http';
}

/// Likewise the host the client actually typed.
String _forwardedHost(HttpRequest request, bool trust) {
  if (trust) {
    final claimed = request.headers
        .value('x-forwarded-host')
        ?.split(',')
        .first
        .trim();
    if (claimed != null && claimed.isNotEmpty) return claimed;
  }
  return request.headers.value('host') ?? '';
}

const _hopByHop = {
  'connection',
  'keep-alive',
  'proxy-authenticate',
  'proxy-authorization',
  'te',
  'trailer',
  'transfer-encoding',
  'upgrade',
};

/// Routes `Host` → site → app port, starting the app when needed.
class ProxyServer {
  ProxyServer({required this.sites, required this.runner, this.log});

  /// Swapped by the daemon on config reload.
  SiteRegistry sites;
  final AppRunner runner;
  final void Function(String message)? log;

  final _servers = <HttpServer>[];
  final _client = HttpClient()..autoUncompress = false;

  List<HttpServer> get servers => List.unmodifiable(_servers);

  /// Read through [sites], which the daemon swaps on reload, so turning
  /// the flag on takes effect without a restart.
  bool get _trustForwarded => sites.config.trustForwardedHeaders;

  Future<HttpServer> listen(
    InternetAddress address,
    int port, {
    SecurityContext? context,
  }) async {
    final server = await _bind(address, port, context);
    _servers.add(server);
    return server;
  }

  /// Closes [server] (force) and replaces it, at the same index in
  /// [servers], with a fresh server bound to [address]/[port]. Used when
  /// the HTTPS leaf certificate is regenerated with a different SAN set
  /// on reload, so existing connections drop but new ones see the new
  /// certificate immediately instead of waiting for a full daemon
  /// restart.
  Future<HttpServer> rebind(
    HttpServer server,
    InternetAddress address,
    int port, {
    SecurityContext? context,
  }) async {
    final index = _servers.indexOf(server);
    await server.close(force: true);
    _servers.remove(server);
    final fresh = await _bind(address, port, context);
    _servers.insert(index, fresh);
    return fresh;
  }

  Future<HttpServer> _bind(
    InternetAddress address,
    int port,
    SecurityContext? context,
  ) async {
    final server = context == null
        ? await HttpServer.bind(address, port)
        : await HttpServer.bindSecure(address, port, context);
    server.autoCompress = false;
    final secure = context != null;
    server.listen(
      // handle() reports its own errors as HTTP responses; catchError only
      // guards against one escaping as an unhandled async error (e.g. a
      // failure after the response socket was already detached).
      (r) => handle(r, secure).catchError(
        (Object e, StackTrace st) => log?.call('unhandled: $e\n$st'),
      ),
      onError: (Object e) => log?.call('server error: $e'),
    );
    return server;
  }

  Future<void> close() async {
    for (final s in _servers) {
      await s.close(force: true);
    }
    _servers.clear();
    _client.close(force: true);
  }

  /// [secure] says whether the listener this request arrived on was
  /// bound with a [SecurityContext] — the only trustworthy source for
  /// `X-Forwarded-Proto`.
  Future<void> handle(HttpRequest request, [bool secure = false]) async {
    final host = request.headers.value('host') ?? '';
    final site = sites.resolveHost(host);
    if (site == null) {
      await _html(
        request,
        404,
        notFoundPage(host, sites.all(), sites.config.tld),
      );
      return;
    }
    try {
      var port = await runner.ensureRunning(site);
      if (!await _accepts(port)) {
        // The app died since we last saw it; start it once more before
        // forwarding, so the request (body, or a WebSocket upgrade) is
        // only ever sent once — a retry after forwarding has begun could
        // resend a consumed body or double-detach the response socket.
        runner.markStopped(site.name);
        port = await runner.ensureRunning(site);
      }
      await _forward(request, site, port, secure);
      runner.touch(site.name);
    } on StartFailed catch (e) {
      await _html(
        request,
        502,
        badGatewayPage(
          site,
          '$host — ${e.message.split('\n').first}',
          e.logTail,
        ),
      );
    } on StartTimeout catch (e) {
      await _html(
        request,
        502,
        badGatewayPage(
          site,
          '$host — ${e.message.split('\n').first}',
          e.logTail,
        ),
      );
    } catch (e, st) {
      log?.call('proxy error for ${site.name}: $e\n$st');
      await _html(
        request,
        502,
        badGatewayPage(
          site,
          '$host — Proxy error: $e',
          runner.logTail(site.name),
        ),
      );
    }
  }

  Future<void> _forward(
    HttpRequest request,
    Site site,
    int port,
    bool secure,
  ) async {
    if (WebSocketTransformer.isUpgradeRequest(request)) {
      await _tunnel(request, site, port, secure);
      return;
    }
    if (_markedForUpgrade(request)) {
      await _tunnel(request, site, port, secure, closeAfterResponse: true);
      return;
    }
    final upstream = await _client.openUrl(
      request.method,
      request.requestedUri.replace(
        scheme: 'http',
        host: '127.0.0.1',
        port: port,
      ),
    );
    upstream.followRedirects = false;
    upstream.persistentConnection = false;
    request.headers.forEach((name, values) {
      final lower = name.toLowerCase();
      if (_hopByHop.contains(lower) || _forwarded.contains(lower)) return;
      for (final v in values) {
        upstream.headers.add(name, v, preserveHeaderCase: true);
      }
    });
    upstream.headers.set('host', request.headers.value('host') ?? '');
    upstream.headers.set(
      'x-forwarded-for',
      request.connectionInfo?.remoteAddress.address ?? '',
    );
    upstream.headers.set(
      'x-forwarded-proto',
      _forwardedProto(request, secure, _trustForwarded),
    );
    upstream.headers.set(
      'x-forwarded-host',
      _forwardedHost(request, _trustForwarded),
    );
    upstream.contentLength = request.contentLength;
    await upstream.addStream(request);
    final response = await upstream.close();
    request.response.statusCode = response.statusCode;
    request.response.reasonPhrase = response.reasonPhrase;
    response.headers.forEach((name, values) {
      if (_hopByHop.contains(name.toLowerCase())) return;
      for (final v in values) {
        request.response.headers.add(name, v, preserveHeaderCase: true);
      }
    });
    request.response.contentLength = response.contentLength;
    await request.response.addStream(response);
    await request.response.close();
  }

  /// Whether the client marked this connection for upgrade, whatever it
  /// then asked to upgrade *to*.
  ///
  /// This is not pedantry. `dart:io` stops delivering the request body
  /// the moment it sees `Connection: upgrade`: the stream ends
  /// immediately while `contentLength` still promises the bytes, so
  /// forwarding such a request as HTTP writes zero bytes against a
  /// content-length that expected more and throws. The bytes are not
  /// lost — they are still unread in the socket — so only the tunnel,
  /// which detaches and pipes, can deliver them.
  ///
  /// nginx makes this the common case, not a rare one. The standard
  /// WebSocket recipe sets `Connection: \$connection_upgrade` from a map
  /// over `\$http_upgrade`; where that map is missing or unconditional —
  /// Herd's is — every ordinary POST arrives marked for an upgrade that
  /// is not happening, and every form submission is silently emptied.
  static bool _markedForUpgrade(HttpRequest request) =>
      request.headers[HttpHeaders.connectionHeader]?.any(
        (value) =>
            value.split(',').any((t) => t.trim().toLowerCase() == 'upgrade'),
      ) ??
      false;

  /// Raw byte tunnel for WebSocket upgrades: send the original request
  /// line and headers to the app, then pipe both directions.
  ///
  /// With [closeAfterResponse] the request is not really an upgrade, so
  /// `Connection` is rewritten to `close`: the app answers and hangs up,
  /// which ends the pipe. Left as `upgrade` the app would keep the
  /// connection open and the tunnel would wait for a close that never
  /// comes.
  ///
  /// Connects to the app *before* detaching the client's response socket:
  /// if the app is unreachable, this throws and `handle` renders the usual
  /// 502 page on the still-intact response, instead of detaching a socket
  /// it then has no working upstream for.
  Future<void> _tunnel(
    HttpRequest request,
    Site site,
    int port,
    bool secure, {
    bool closeAfterResponse = false,
  }) async {
    final upstream = await Socket.connect(InternetAddress.loopbackIPv4, port);
    final client = await request.response.detachSocket(writeHeaders: false);
    final head = StringBuffer()
      ..write('${request.method} ${request.requestedUri.path}')
      ..write(
        request.requestedUri.hasQuery ? '?${request.requestedUri.query}' : '',
      )
      ..write(' HTTP/1.1\r\n');
    request.headers.forEach((name, values) {
      final lower = name.toLowerCase();
      if (_forwarded.contains(lower)) return;
      if (closeAfterResponse && lower == HttpHeaders.connectionHeader) return;
      for (final v in values) {
        head.write('$name: $v\r\n');
      }
    });
    head
      ..write(closeAfterResponse ? 'connection: close\r\n' : '')
      ..write(
        'x-forwarded-proto: '
        '${_forwardedProto(request, secure, _trustForwarded)}\r\n',
      )
      ..write(
        'x-forwarded-for: ${request.connectionInfo?.remoteAddress.address ?? ''}\r\n',
      )
      ..write(
        'x-forwarded-host: ${_forwardedHost(request, _trustForwarded)}\r\n',
      )
      ..write('\r\n');
    upstream.write(head.toString());
    // A tunnel carries no further requests, so nothing touches the app
    // again until it closes: tell the runner to hold it open meanwhile.
    runner.openTunnel(site.name);
    var accounted = false;
    void closed() {
      if (accounted) return;
      accounted = true;
      runner.closeTunnel(site.name);
      runner.touch(site.name);
    }

    unawaited(
      upstream
          .addStream(client)
          .whenComplete(closed)
          .then(
            (_) => upstream.close(),
            onError: (Object _) => upstream.close(),
          ),
    );
    unawaited(
      client
          .addStream(upstream)
          .whenComplete(closed)
          .then((_) => client.close(), onError: (Object _) => client.close()),
    );
  }

  /// Whether the app is actually accepting connections on [port] right
  /// now, so `handle` can restart it once *before* forwarding rather than
  /// discovering it is dead mid-forward and having to retry a
  /// partially-sent request.
  Future<bool> _accepts(int port) async {
    try {
      final socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        port,
        timeout: const Duration(milliseconds: 500),
      );
      socket.destroy();
      return true;
    } on SocketException {
      return false;
    }
  }

  Future<void> _html(HttpRequest request, int status, String html) async {
    try {
      request.response
        ..statusCode = status
        ..headers.contentType = ContentType.html
        ..write(html);
      await request.response.close();
    } catch (e) {
      // The response socket may already be detached/closed (e.g. a
      // WebSocket tunnel failure after detachSocket). Log rather than
      // throw again out of an error handler.
      log?.call('failed to write error page: $e');
    }
  }
}
