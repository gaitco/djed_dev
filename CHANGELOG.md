## 0.1.0

Initial release.

- CLI: `install`/`uninstall [--purge]`, `start`/`stop`/`restart [site]`, `status`, `park [dir]`/`forget [dir]`, `link [name] [dir]`/`unlink [name]`/`links`, `log [site] [-f]`, `open [site]`, `secure [--restart]`, `daemon`.
- DNS: a UDP responder on `127.0.0.1:53535` answering `*.test` with `A`/`AAAA` records; queries outside the tld are refused.
- TLS: a local certificate authority plus one leaf whose SANs list every registered site (`name.test`, `*.name.test`) alongside `test`, `localhost` and `127.0.0.1`; regenerated when the site list changes or the leaf nears expiry.
- Proxy: HTTP on 80 and HTTPS on 443, routed by `Host`, WebSocket tunnelling, `X-Forwarded-*` headers, inline 404/502 pages with the site's log tail.
- App lifecycle: apps start on first request (`dart run bin/server.dart` with `APP_HOST`/`APP_PORT`/`APP_URL`), stop after 15 minutes idle, restart when `lib/`, `routes/`, `config/`, `bootstrap/` or `pubspec.yaml` change.
- macOS platform: `/etc/resolver`, System keychain trust and a launchd agent, each `sudo` step announced before it prompts.
- Config: `~/.config/djed/config.json` (or `$DJED_HOME`) tracks parked directories and links; a control socket reloads a running daemon without restarting it.
