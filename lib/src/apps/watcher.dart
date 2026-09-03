import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../sites.dart';

/// Watches the code paths of a site and fires [onChange] once per burst
/// of edits.
class ChangeWatcher {
  ChangeWatcher(
    this.site,
    this.onChange, {
    this.debounce = const Duration(milliseconds: 500),
  });

  static const watchedPaths = [
    'lib',
    'routes',
    'config',
    'bootstrap',
    'pubspec.yaml',
  ];

  /// How long after [start] an event for a watched directory's own path is
  /// treated as FSEvents replay noise rather than a real change.
  static const _directoryRootGrace = Duration(seconds: 1);

  final Site site;
  final void Function() onChange;
  final Duration debounce;

  final _subscriptions = <StreamSubscription<FileSystemEvent>>[];
  final _directoryRoots = <String>{};
  DateTime? _startedAt;
  Timer? _timer;

  Future<void> start() async {
    _startedAt = DateTime.now();
    for (final relative in watchedPaths) {
      final path = p.join(site.path, relative);
      final type = FileSystemEntity.typeSync(path);
      if (type == FileSystemEntityType.notFound) continue;
      final isDirectory = type == FileSystemEntityType.directory;
      if (isDirectory) _directoryRoots.add(path);
      final stream = isDirectory
          ? Directory(path).watch(recursive: true)
          : File(path).watch();
      _subscriptions.add(stream.listen(_onEvent));
    }
  }

  void _onEvent(FileSystemEvent event) {
    // macOS FSEvents can replay create and modify events for a watched
    // directory's own path right after the watch starts. Real file changes
    // report the child's path, so only root events inside the grace window
    // are discarded.
    final isStartupNoise =
        _directoryRoots.contains(event.path) &&
        _startedAt != null &&
        DateTime.now().difference(_startedAt!) < _directoryRootGrace;
    if (isStartupNoise) return;
    _timer?.cancel();
    _timer = Timer(debounce, onChange);
  }

  Future<void> stop() async {
    _timer?.cancel();
    for (final s in _subscriptions) {
      await s.cancel();
    }
    _subscriptions.clear();
  }
}
