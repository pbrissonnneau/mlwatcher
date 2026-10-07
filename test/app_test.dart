import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mlwatcher/src/app/watcher_service.dart';
import 'package:mlwatcher/src/data/json_store.dart';
import 'package:mlwatcher/src/data/secret_store.dart';
import 'package:mlwatcher/src/data/settings.dart';
import 'package:mlwatcher/src/platform/notifier.dart';
import 'package:mlwatcher/src/ui/overlay_view.dart';
import 'package:mlwatcher/src/ui/theme.dart';

import 'fake_mlflow.dart';

class RecordingNotifier extends Notifier {
  final shown = <String>[];

  @override
  Future<void> show({required String title, required String body, VoidCallback? onClick}) async => shown.add(title);
}

void main() {
  late Directory dir;
  late FakeMlflow server;
  late RecordingNotifier notifier;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('mlwatcher_test');
    server = FakeMlflow();
    notifier = RecordingNotifier();
  });

  tearDown(() => dir.delete(recursive: true));

  Future<WatcherService> service({Settings settings = const Settings(serverUrl: 'http://mlflow.test')}) async {
    final store = JsonStore(dir);
    await store.saveSettings(settings);
    final s = WatcherService(
      store: store,
      secrets: SecretStore(dir),
      notifier: notifier,
      pollInterval: const Duration(hours: 1), // Polls are driven by the test.
      clientFactory: (_) => server.client(),
    );
    await s.load();
    return s;
  }

  Future<void> pollNow(WatcherService s) async {
    s.start();
    await pumpEventQueue();
  }

  int now() => DateTime.now().millisecondsSinceEpoch;

  test('polls, notifies ended runs and persists the shown runs', () async {
    server.add(FakeRun('a', startTime: now() - 60000));
    final s = await service();
    await pollNow(s);
    expect([for (final r in s.runs) r.id], ['a']);
    expect(notifier.shown, isEmpty);

    server.runs['a']!.status = 'FAILED';
    await pollNow(s);
    expect(notifier.shown, ['Run failed: run-a']);
    expect(s.hasUndismissedFailure, isTrue);

    // Survives a restart.
    final (runs, _) = await JsonStore(dir).loadState();
    expect(runs.single.id, 'a');
    s.dispose();
  });

  test('notifications follow the settings', () async {
    server.add(FakeRun('a', startTime: now() - 60000));
    final s = await service(settings: const Settings(serverUrl: 'http://mlflow.test', notifyOnFinish: false));
    await pollNow(s);
    server.runs['a']!.status = 'FINISHED';
    await pollNow(s);
    expect(notifier.shown, isEmpty);
    s.dispose();
  });

  test('while the server is unreachable no run is shown', () async {
    server.add(FakeRun('a', startTime: now() - 60000));
    final s = await service();
    await pollNow(s);
    server.down = true;
    await pollNow(s);
    expect(s.error, contains('Cannot reach server'));
    expect(s.runs, isEmpty);
    server.down = false;
    await pollNow(s);
    expect(s.error, isNull);
    expect(s.runs, hasLength(1));
    s.dispose();
  });

  test('settings and secret are saved', () async {
    final s = await service();
    await s.applySettings(s.settings.copyWith(userFilter: 'bob'), 's3cret');
    final again = await service(settings: await JsonStore(dir).loadSettings());
    expect(again.settings.userFilter, 'bob');
    expect(again.secret, 's3cret');
    s.dispose();
    again.dispose();
  });

  testWidgets('overlay shows runs; right-click dismisses', (tester) async {
    late WatcherService s;
    await tester.runAsync(() async {
      server
        ..add(FakeRun('a', startTime: now() - 60000, epoch: 3, totalEpochs: '10'))
        ..add(FakeRun('b', startTime: now() - 120000));
      s = await service();
      await pollNow(s);
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: OverlayView(service: s, onToggleOnTop: () {}, onHide: () {}, onOpenSettings: () {}, resizable: false),
      ),
    );
    expect(find.text('run-a'), findsOneWidget);
    expect(find.text('run-b'), findsOneWidget);
    expect(find.text('3/10'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);

    await tester.tap(find.text('run-b'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Dismiss'));
    await tester.pumpAndSettle();
    expect(find.text('run-b'), findsNothing);
    expect(find.text('run-a'), findsOneWidget);

    await tester.runAsync(() async {
      server.down = true;
      await pollNow(s);
    });
    await tester.pump();
    expect(find.text('run-a'), findsNothing);
    expect(find.textContaining('Cannot reach server'), findsOneWidget);
    s.dispose();
  });
  testWidgets('overlay reports the height of its first lines', (tester) async {
    late WatcherService s;
    await tester.runAsync(() async {
      for (final id in ['a', 'b', 'c']) {
        server.add(FakeRun(id, startTime: now() - 60000));
      }
      s = await service(settings: const Settings(serverUrl: 'http://mlflow.test', maxVisibleRuns: 2));
      await pollNow(s);
    });
    final heights = <double>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: OverlayView(
          service: s,
          onToggleOnTop: () {},
          onHide: () {},
          onOpenSettings: () {},
          onContentHeight: heights.add,
          resizable: false,
        ),
      ),
    );
    await tester.pump();
    final rowHeight = tester.getSize(find.byType(RunRow).first).height;
    expect(heights.last, moreOrLessEquals(20 + 4 + 2 * rowHeight));

    await tester.runAsync(() => s.updateDisplay(s.settings.copyWith(maxVisibleRuns: 10)));
    await tester.pump();
    await tester.pump();
    expect(heights.last, moreOrLessEquals(20 + 4 + 3 * rowHeight));

    await tester.runAsync(() async {
      server.down = true;
      await pollNow(s);
    });
    await tester.pump();
    await tester.pump();
    expect(heights.last, lessThan(20 + 4 + 2 * rowHeight));
    s.dispose();
  });
}
