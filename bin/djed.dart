import 'dart:io';

import 'package:djed_dev/djed_dev.dart';

Future<void> main(List<String> args) async {
  if (!Platform.isMacOS) {
    stderr.writeln('djed supports macOS only in this version.');
    exit(1);
  }
  final code = await runDjed(
    args,
    platform: MacOsPlatform(environment: Platform.environment),
    paths: DjedPaths.resolve(),
  );
  exit(code);
}
