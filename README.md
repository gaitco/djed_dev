# Djed Local Development

<p align="center"><img src="assets/icon.svg" width="96" alt="Djed icon"></p>

Valet-style local environment for Maat apps: every app in a parked
directory is `https://<name>.test`, trusted in Safari and Chrome, started on
first request, restarted when its code changes, stopped when idle. Pure
Dart; no Homebrew services.

## Install (macOS)

```sh
dart pub global activate --source path packages/djed_dev   # or from pub.dev later
djed install        # asks for sudo three times (see below)
djed park ~/Sites   # every child with bin/server.dart becomes <dir>.test
djed link blog      # or one directory under a chosen name
djed status
```

If Herd or Valet is running, `install` stops and tells you to run
`herd stop` or `valet stop` first: both cannot own ports 80 and 443.

`install` needs `sudo` for three things, and announces each before it
prompts: `/etc/resolver/test`, trusting the CA in the System keychain,
and installing `/Library/LaunchDaemons/com.maat.djed.plist`.
`uninstall` removes all three. Re-running `install` boots the daemon out
before loading the new job, so every app it was running stops with it.

## Root, and why

The daemon is a **LaunchDaemon**, so it runs as root. Only root may bind
ports below 1024 on macOS, and `https://blog.test` with no port number is
the entire point of the tool. Valet and Herd solve it the same way.

Your applications do not run as root. The plist carries your username in
`DJED_USER`; the daemon hands `~/.config/djed` back to you, keeps its
control socket yours and 0600, and starts every app through
`sudo -u <you> -H`, so project files, databases and caches stay yours.
Because `config.json` is yours to edit, a root daemon does not trust all
of it: `openssl` is ignored (the plist's path, then `PATH`), and no port
below 1024 other than 80 and 443 is honoured — on start and on every
reload. Everything else it acts on as written.
Apps still live in the system bootstrap rather than your login session:
no login keychain, and no TCC prompts for Documents or Desktop. Valet
behaves the same way.

## Commands

| Command | Does |
|---|---|
| `install` / `uninstall [--purge]` | set up or remove DNS, CA and the LaunchDaemon |
| `start` / `stop` / `restart [site]` | daemon or one app |
| `status` | pid, ports, DNS check, certificate expiry, running apps |
| `park [dir]` / `forget [dir]` | directories of apps |
| `link [name] [dir]` / `unlink [name]` / `links` | single apps |
| `log [site] [-f]` | daemon or app log |
| `open [site]` | open in the browser |
| `secure [--restart]` | regenerate the certificate and re-trust the CA |
| `daemon` | foreground daemon (launchd runs this as root) |

## How it works

- DNS: a UDP responder on `127.0.0.1:53535` answers `*.test`; `/etc/resolver/test` sends it there.
- TLS: one CA in `~/.config/djed/ca`; one leaf in `~/.config/djed/certs` listing `test`, `localhost`, `127.0.0.1` and, per registered site, `<name>.test` + `*.<name>.test` — never a single `*.test` wildcard, which strict hostname verification rejects. Regenerated (and HTTPS rebound) whenever the site list changes; 825 days.
- Proxy: HTTP on 80 and HTTPS on 443 route by `Host` to the app's port, forward WebSockets, add `X-Forwarded-*`.
- Daemon: a root LaunchDaemon (nothing else can bind 80 and 443); apps drop back to you through `sudo -u`.
- Apps: `dart run bin/server.dart` — the absolute `dart`, since launchd's PATH is only `/usr/bin:/bin:/usr/sbin:/sbin` — with `APP_HOST`, `APP_PORT`, `APP_URL`; logs in `~/.config/djed/logs`; idle apps stop after 15 minutes; edits under `lib/`, `routes/`, `config/`, `bootstrap/` or `pubspec.yaml` restart the app.

## Limitations

- macOS only. Linux (systemd, resolved) and Windows are on the roadmap.
- One wildcard label: `api.blog.test` works, `a.b.blog.test` routes but its certificate does not match.
- Only Maat-shaped apps (`bin/server.dart` honouring `APP_PORT`). Custom start commands are a follow-up.
- No GUI.
