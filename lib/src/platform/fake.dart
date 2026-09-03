import 'dart:io';

import 'platform.dart';

/// Records every call; returns configured results.
class FakePlatform extends DjedPlatform {
  final calls = <String>[];
  List<PortOwner> listenersResult = const [];
  bool agentRunningResult = false;

  @override
  Future<void> writeResolver(String tld, int port) async =>
      calls.add('writeResolver $tld $port');
  @override
  Future<void> removeResolver(String tld) async =>
      calls.add('removeResolver $tld');
  @override
  Future<void> trustCa(File pem) async => calls.add('trustCa ${pem.path}');
  @override
  Future<void> untrustCa(File pem) async => calls.add('untrustCa ${pem.path}');
  @override
  Future<void> installAgent(String plist) async => calls.add('installAgent');
  @override
  Future<void> uninstallAgent() async => calls.add('uninstallAgent');
  @override
  Future<void> startAgent() async => calls.add('startAgent');
  @override
  Future<void> stopAgent() async => calls.add('stopAgent');
  @override
  Future<bool> agentRunning() async => agentRunningResult;
  @override
  Future<List<PortOwner>> listeners(List<int> ports) async => listenersResult;
  @override
  Future<void> openUrl(String url) async => calls.add('openUrl $url');
}
