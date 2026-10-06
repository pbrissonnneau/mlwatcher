import 'package:flutter/foundation.dart';
import 'package:local_notifier/local_notifier.dart';

/// Desktop notifications (Windows toasts, libnotify on Linux).
class Notifier {
  bool _ready = false;

  Future<void> init() async {
    try {
      await localNotifier.setup(appName: 'mlwatcher', shortcutPolicy: ShortcutPolicy.requireCreate);
      _ready = true;
    } catch (e) {
      debugPrint('Notifications unavailable: $e');
    }
  }

  Future<void> show({required String title, required String body, VoidCallback? onClick}) async {
    if (!_ready) return;
    try {
      final n = LocalNotification(title: title, body: body)..onClick = onClick;
      await n.show();
    } catch (e) {
      debugPrint('Notification failed: $e');
    }
  }
}
