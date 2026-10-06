import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'src/app/mlwatcher_app.dart';
import 'src/app/watcher_service.dart';
import 'src/data/json_store.dart';
import 'src/data/secret_store.dart';
import 'src/platform/notifier.dart';
import 'src/platform/shell.dart';
import 'src/platform/single_instance.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  final dataDir = await getApplicationSupportDirectory();
  await dataDir.create(recursive: true);

  // A second launch only brings the running overlay to the front.
  final instance = SingleInstance(dataDir);
  if (!await instance.tryAcquire()) {
    await instance.signalRunningInstance();
    exit(0);
  }

  final notifier = Notifier();
  final service = WatcherService(store: JsonStore(dataDir), secrets: SecretStore(dataDir), notifier: notifier);
  await service.load();

  final shell = Shell(service);
  await shell.init();
  instance.showRequests.listen((_) => unawaited(shell.showOverlay()));
  unawaited(instance.listen());

  runApp(MlwatcherApp(service: service, shell: shell));

  WidgetsBinding.instance.addPostFrameCallback((_) async {
    await notifier.init();
    service.start();
    // First start: nothing to watch yet, go straight to the settings.
    if (!service.settings.isConfigured) await shell.openSettings();
  });
}
