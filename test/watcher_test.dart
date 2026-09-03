import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:maat_djed/maat_djed.dart';
import 'package:test/test.dart';

void main() {
  late Directory app;
  setUp(() {
    app = Directory.systemTemp.createTempSync('djed_watch');
    for (final d in ['lib', 'routes', 'resources/views']) {
      Directory(p.join(app.path, d)).createSync(recursive: true);
    }
  });
  tearDown(() => app.deleteSync(recursive: true));

  test(
    'debounces a burst of edits under watched paths into one change',
    () async {
      var changes = 0;
      final watcher = ChangeWatcher(
        Site('a', app.path),
        () => changes++,
        debounce: const Duration(milliseconds: 200),
      );
      await watcher.start();
      for (var i = 0; i < 5; i++) {
        File(p.join(app.path, 'lib', 'f$i.dart')).writeAsStringSync('x');
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(changes, 1);
      File(p.join(app.path, 'routes', 'web.dart')).writeAsStringSync('y');
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(changes, 2);
      await watcher.stop();
    },
  );

  test('ignores unwatched paths', () async {
    var changes = 0;
    final watcher = ChangeWatcher(
      Site('a', app.path),
      () => changes++,
      debounce: const Duration(milliseconds: 100),
    );
    await watcher.start();
    File(
      p.join(app.path, 'resources', 'views', 'x.khnum.html'),
    ).writeAsStringSync('x');
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(changes, 0);
    await watcher.stop();
  });

  test('watches pubspec.yaml edits', () async {
    final pubspec = File(p.join(app.path, 'pubspec.yaml'))
      ..writeAsStringSync('name: a\n');
    var changes = 0;
    final watcher = ChangeWatcher(
      Site('a', app.path),
      () => changes++,
      debounce: const Duration(milliseconds: 100),
    );
    await watcher.start();
    pubspec.writeAsStringSync('name: a\nversion: 1.0.0\n');
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(changes, 1);
    await watcher.stop();
  });
}
