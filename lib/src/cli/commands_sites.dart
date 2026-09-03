import 'dart:io';

import 'package:path/path.dart' as p;

import '../sites.dart';
import 'runner.dart';

class ParkCommand extends DjedCommand {
  ParkCommand(super.context);
  @override
  String get name => 'park';
  @override
  String get description => 'Serve every app in a directory: djed park [dir]';
  @override
  Future<int> run() async {
    final dir = p.canonicalize(
      argResults!.rest.firstOrNull ?? Directory.current.path,
    );
    final config = await context.config();
    if (!config.paths.contains(dir)) {
      await config.copyWith(paths: [...config.paths, dir]).save(paths);
    }
    await context.reload();
    out.writeln('Parked $dir');
    return 0;
  }
}

class ForgetCommand extends DjedCommand {
  ForgetCommand(super.context);
  @override
  String get name => 'forget';
  @override
  String get description => 'Stop serving a parked directory';
  @override
  Future<int> run() async {
    final dir = p.canonicalize(
      argResults!.rest.firstOrNull ?? Directory.current.path,
    );
    final config = await context.config();
    await config
        .copyWith(paths: config.paths.where((x) => x != dir).toList())
        .save(paths);
    await context.reload();
    out.writeln('Forgot $dir');
    return 0;
  }
}

class LinkCommand extends DjedCommand {
  LinkCommand(super.context);
  @override
  String get name => 'link';
  @override
  String get description =>
      'Serve one app under a name: djed link [name] [dir]';
  @override
  Future<int> run() async {
    final rest = argResults!.rest;
    final dir = p.canonicalize(
      rest.length > 1 ? rest[1] : Directory.current.path,
    );
    final name = rest.isNotEmpty
        ? normalizeSiteName(rest.first)
        : normalizeSiteName(p.basename(dir));
    // A name that normalizes away entirely (`!!!`) or overruns a DNS
    // label would be written to the config and then break every later
    // certificate generation, recoverable only by editing the file.
    if (name.isEmpty || name.length > 63) {
      err.writeln(
        'Cannot serve a site as "$name": a site name needs 1-63 characters '
        'of letters, digits, dots or dashes.',
      );
      return 1;
    }
    if (!SiteRegistry.isApp(dir)) {
      err.writeln('$dir has no bin/server.dart; is it a Maat app?');
      return 1;
    }
    final config = await context.config();
    await config.copyWith(links: {...config.links, name: dir}).save(paths);
    await context.reload();
    out.writeln('Linked ${config.url(name)} → $dir');
    return 0;
  }
}

class UnlinkCommand extends DjedCommand {
  UnlinkCommand(super.context);
  @override
  String get name => 'unlink';
  @override
  String get description => 'Remove a link: djed unlink [name]';
  @override
  Future<int> run() async {
    final name =
        argResults!.rest.firstOrNull ??
        normalizeSiteName(p.basename(Directory.current.path));
    final config = await context.config();
    final links = {...config.links}..remove(name);
    await config.copyWith(links: links).save(paths);
    await context.reload();
    out.writeln('Unlinked $name');
    return 0;
  }
}

class LinksCommand extends DjedCommand {
  LinksCommand(super.context);
  @override
  String get name => 'links';
  @override
  String get description => 'List every site';
  @override
  Future<int> run() async {
    final config = await context.config();
    final client = await context.control();
    final running = <String>{};
    if (client != null) {
      final status = await client.send({'cmd': 'status'});
      running.addAll(
        (status['apps'] as List).map((a) => (a as Map)['name'] as String),
      );
    }
    final sites = SiteRegistry(config).all();
    if (sites.isEmpty) {
      out.writeln('No sites. Use: djed park [dir]  or  djed link [name]');
      return 0;
    }
    for (final s in sites) {
      out.writeln(
        '${s.name.padRight(20)} ${config.url(s.name).padRight(32)} ${running.contains(s.name) ? 'running' : 'stopped'}  ${s.path}',
      );
    }
    return 0;
  }
}

class OpenCommand extends DjedCommand {
  OpenCommand(super.context);
  @override
  String get name => 'open';
  @override
  String get description => 'Open a site in the browser: djed open [name]';
  @override
  Future<int> run() async {
    final config = await context.config();
    final name =
        argResults!.rest.firstOrNull ??
        normalizeSiteName(p.basename(Directory.current.path));
    await platform.openUrl(config.url(name));
    return 0;
  }
}
