import 'dart:io';

import 'package:path/path.dart' as p;

import 'config.dart';

/// One application: `name.<tld>` served from [path].
class Site {
  const Site(this.name, this.path);

  final String name;
  final String path;

  @override
  String toString() => 'Site($name → $path)';
}

/// `My Blog_App` → `my-blog-app`: lowercase, runs of anything but
/// `[a-z0-9.]` become one dash, dashes trimmed from the ends.
String normalizeSiteName(String name) => name
    .toLowerCase()
    .replaceAll(RegExp(r'[^a-z0-9.]+'), '-')
    .replaceAll(RegExp(r'\.{2,}'), '-')
    .replaceAll(RegExp(r'^[-.]+|[-.]+$'), '');

/// Sites from parked directories and explicit links.
class SiteRegistry {
  SiteRegistry(this.config);

  final DjedConfig config;

  /// Links first (they win), then every parked child with `bin/server.dart`.
  List<Site> all() {
    final byName = <String, Site>{};
    for (final parked in config.paths) {
      final dir = Directory(parked);
      if (!dir.existsSync()) continue;
      final children = dir.listSync().whereType<Directory>().toList()
        ..sort((a, b) => a.path.compareTo(b.path));
      for (final child in children) {
        if (!isApp(child.path)) continue;
        final name = normalizeSiteName(p.basename(child.path));
        if (name.isNotEmpty) {
          byName.putIfAbsent(name, () => Site(name, child.path));
        }
      }
    }
    for (final entry in config.links.entries) {
      byName[entry.key] = Site(entry.key, entry.value);
    }
    final sites = byName.values.toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    return sites;
  }

  Site? find(String name) => all().where((s) => s.name == name).firstOrNull;

  /// `Host: v2.api.blog.test:443` → tries `v2.api.blog`, `api.blog`, `blog`.
  Site? resolveHost(String host) {
    var name = host.toLowerCase();
    final colon = name.indexOf(':');
    if (colon >= 0) name = name.substring(0, colon);
    final suffix = '.${config.tld}';
    if (!name.endsWith(suffix)) return null;
    var labels = name.substring(0, name.length - suffix.length).split('.');
    final sites = {for (final s in all()) s.name: s};
    while (labels.isNotEmpty) {
      final site = sites[labels.join('.')];
      if (site != null) return site;
      labels = labels.sublist(1);
    }
    return null;
  }

  static bool isApp(String path) =>
      File(p.join(path, 'bin', 'server.dart')).existsSync();
}
