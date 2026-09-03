import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:djed_dev/djed_dev.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;

  Directory app(String name) {
    final dir = Directory(p.join(root.path, name))..createSync(recursive: true);
    File(p.join(dir.path, 'bin', 'server.dart'))
      ..createSync(recursive: true)
      ..writeAsStringSync('void main() {}');
    return dir;
  }

  setUp(() => root = Directory.systemTemp.createTempSync('djed_sites'));
  tearDown(() => root.deleteSync(recursive: true));

  test('normalizeSiteName lowercases and dashes', () {
    expect(normalizeSiteName('My Blog_App'), 'my-blog-app');
    expect(normalizeSiteName('todo'), 'todo');
    expect(normalizeSiteName('Weird..Name!'), 'weird-name');
  });

  test('parked directories expose children with bin/server.dart', () {
    app('blog');
    app('Shop App');
    Directory(p.join(root.path, 'notes')).createSync();
    final registry = SiteRegistry(DjedConfig(paths: [root.path]));
    expect(registry.all().map((s) => s.name), ['blog', 'shop-app']);
    expect(registry.find('shop-app')!.path, p.join(root.path, 'Shop App'));
    expect(registry.find('notes'), isNull);
  });

  test('links win over parked sites and missing paths are skipped', () {
    app('blog');
    final linked = app('other');
    final registry = SiteRegistry(
      DjedConfig(paths: [root.path, '/nope'], links: {'blog': linked.path}),
    );
    expect(registry.find('blog')!.path, linked.path);
    expect(registry.all().length, 2);
  });

  test('resolveHost walks the label chain and respects the tld', () {
    app('blog');
    app('api.blog');
    final registry = SiteRegistry(DjedConfig(paths: [root.path]));
    expect(registry.resolveHost('blog.test')!.name, 'blog');
    expect(registry.resolveHost('api.blog.test')!.name, 'api.blog');
    expect(registry.resolveHost('v2.api.blog.test')!.name, 'api.blog');
    expect(registry.resolveHost('www.blog.test')!.name, 'blog');
    expect(registry.resolveHost('BLOG.TEST:443')!.name, 'blog');
    expect(registry.resolveHost('blog.local'), isNull);
    expect(registry.resolveHost('nope.test'), isNull);
    expect(registry.resolveHost('test'), isNull);
  });
}
