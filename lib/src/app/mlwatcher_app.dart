import 'dart:async';

import 'package:flutter/material.dart';

import '../platform/shell.dart';
import '../ui/overlay_view.dart';
import '../ui/settings_view.dart';
import '../ui/theme.dart';
import 'watcher_service.dart';

class MlwatcherApp extends StatelessWidget {
  const MlwatcherApp({super.key, required this.service, required this.shell});

  final WatcherService service;
  final Shell shell;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'mlwatcher',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      home: ValueListenableBuilder(
        valueListenable: shell.mode,
        builder: (context, mode, _) => switch (mode) {
          ShellMode.overlay => OverlayView(
            service: service,
            onToggleOnTop: () => unawaited(shell.toggleAlwaysOnTop()),
            onHide: () => unawaited(shell.hideOverlay()),
            onOpenSettings: () => unawaited(shell.openSettings()),
          ),
          ShellMode.settings => SettingsView(
            service: service,
            onClose: (saved) async {
              await shell.closeSettings();
              if (saved) await shell.applyDisplaySettings();
            },
          ),
        },
      ),
    );
  }
}
