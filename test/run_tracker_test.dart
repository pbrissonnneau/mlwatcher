import 'package:flutter_test/flutter_test.dart';
import 'package:mlwatcher/src/domain/run_tracker.dart';
import 'package:mlwatcher/src/domain/watched_run.dart';
import 'package:mlwatcher/src/mlflow/mlflow_client.dart';
import 'package:mlwatcher/src/mlflow/mlflow_models.dart';

import 'fake_mlflow.dart';

void main() {
  late FakeMlflow server;
  late DateTime now;
  final t0 = DateTime(2026, 10, 6, 12).millisecondsSinceEpoch;
  int minutes(int m) => t0 + m * 60000;

  RunTracker tracker({
    WatchConfig config = const WatchConfig(),
    List<WatchedRun> runs = const [],
    Map<String, int> dismissed = const {},
  }) => RunTracker(client: server.client(), config: config, now: () => now, runs: runs, dismissed: dismissed);

  List<String> ids(RunTracker t) => [for (final r in t.runs) r.id];

  setUp(() {
    server = FakeMlflow();
    now = DateTime.fromMillisecondsSinceEpoch(minutes(120));
  });

  group('first poll', () {
    test('shows running runs and failures newer than the oldest running run', () async {
      server
        ..add(FakeRun('a', startTime: minutes(10)))
        ..add(FakeRun('b', startTime: minutes(50), experimentId: '2'))
        ..add(FakeRun('old-fail', status: 'FAILED', startTime: minutes(5), endTime: minutes(6)))
        ..add(FakeRun('new-fail', status: 'FAILED', startTime: minutes(20), endTime: minutes(30)))
        ..add(FakeRun('killed', status: 'KILLED', startTime: minutes(60), endTime: minutes(61)))
        ..add(FakeRun('done', status: 'FINISHED', startTime: minutes(40), endTime: minutes(45)));
      final t = tracker();
      final events = await t.poll();
      expect(events, isEmpty, reason: 'no notification for the start-up backlog');
      expect(ids(t), ['killed', 'b', 'new-fail', 'a']);
      expect(t.runs.firstWhere((r) => r.id == 'b').experimentName, 'bert');
    });

    test('shows no failure when nothing is running', () async {
      server.add(FakeRun('f', status: 'FAILED', startTime: minutes(100), endTime: minutes(101)));
      final t = tracker();
      await t.poll();
      expect(t.runs, isEmpty);
    });
  });

  group('later polls', () {
    test('a run that ends stays, with its new status, and is reported', () async {
      server
        ..add(FakeRun('a', startTime: minutes(10)))
        ..add(FakeRun('b', startTime: minutes(11)));
      final t = tracker();
      await t.poll();
      server.runs['a']!
        ..status = 'FAILED'
        ..endTime = minutes(121);
      server.runs['b']!
        ..status = 'FINISHED'
        ..endTime = minutes(121);
      now = now.add(const Duration(seconds: 2));
      final events = await t.poll();
      expect([
        for (final e in events) (e.run.id, e.run.status),
      ], unorderedEquals([('a', MlflowStatus.failed), ('b', MlflowStatus.finished)]));
      expect(ids(t), ['b', 'a']);
      // Nothing more to report on the next round.
      now = now.add(const Duration(seconds: 2));
      expect(await t.poll(), isEmpty);
      expect(ids(t), ['b', 'a']);
    });

    test('a run that started and failed between two polls is caught', () async {
      server.add(FakeRun('a', startTime: minutes(10)));
      final t = tracker();
      await t.poll();
      server
        ..add(FakeRun('quick', status: 'FAILED', startTime: minutes(120) + 500, endTime: minutes(120) + 1500))
        ..add(FakeRun('tiny', status: 'FINISHED', startTime: minutes(120) + 500, endTime: minutes(120) + 900));
      now = now.add(const Duration(seconds: 2));
      final events = await t.poll();
      expect([for (final e in events) e.run.id], ['quick']);
      expect(ids(t), ['quick', 'a'], reason: 'short successful runs are not added');
    });

    test('new running runs appear', () async {
      final t = tracker();
      await t.poll();
      expect(t.runs, isEmpty);
      server.add(FakeRun('n', startTime: minutes(119)));
      now = now.add(const Duration(seconds: 2));
      await t.poll();
      expect(ids(t), ['n']);
    });

    test('epoch, total and progress are updated', () async {
      final run = FakeRun('a', startTime: minutes(10), epoch: 3, totalEpochs: '10');
      server.add(run);
      final t = tracker();
      await t.poll();
      expect(t.runs.single.progress, closeTo(0.3, 1e-9));
      run.epoch = 7;
      await t.poll();
      expect(t.runs.single.epoch, 7);
      expect(t.runs.single.totalEpochs, 10);
    });

    test('a run deleted on the server disappears', () async {
      server.add(FakeRun('a', startTime: minutes(10)));
      final t = tracker();
      await t.poll();
      server.runs.remove('a');
      await t.poll();
      expect(t.runs, isEmpty);
    });
  });

  group('dismiss', () {
    test('removes the run and keeps it hidden while it runs', () async {
      server.add(FakeRun('a', startTime: minutes(10)));
      final t = tracker();
      await t.poll();
      t.dismiss('a');
      expect(t.runs, isEmpty);
      await t.poll();
      expect(t.runs, isEmpty);
      expect(t.dismissed.keys, ['a']);
    });

    test('a dismissed failure does not come back on restart', () async {
      server
        ..add(FakeRun('a', startTime: minutes(10)))
        ..add(FakeRun('f', status: 'FAILED', startTime: minutes(20), endTime: minutes(21)));
      final t = tracker();
      await t.poll();
      t.dismiss('f');
      final restarted = tracker(runs: t.runs, dismissed: t.dismissed);
      await restarted.poll();
      expect(ids(restarted), ['a']);
    });
  });

  test('runs restored from disk are refreshed (finished while closed)', () async {
    server.add(FakeRun('a', status: 'FINISHED', startTime: minutes(10), endTime: minutes(100)));
    final restored = WatchedRun(
      id: 'a',
      name: 'run-a',
      experimentId: '1',
      experimentName: 'resnet',
      status: MlflowStatus.running,
      startTime: minutes(10),
    );
    final t = tracker(runs: [restored]);
    final events = await t.poll();
    expect(events, isEmpty);
    expect(t.runs.single.status, MlflowStatus.finished);
  });

  test('a server error leaves the state unchanged', () async {
    server.add(FakeRun('a', startTime: minutes(10)));
    final t = tracker();
    await t.poll();
    server.runs['a']!.status = 'FAILED';
    server.down = true;
    await expectLater(t.poll(), throwsA(isA<MlflowException>()));
    expect(t.runs.single.status, MlflowStatus.running);
    server.down = false;
    final events = await t.poll();
    expect(events.single.run.status, MlflowStatus.failed);
  });

  group('filters', () {
    test('experiment names restrict the watched experiments', () async {
      server
        ..add(FakeRun('a', startTime: minutes(10)))
        ..add(FakeRun('b', startTime: minutes(10), experimentId: '2'));
      final t = tracker(config: const WatchConfig(experimentNames: ['bert']));
      await t.poll();
      expect(ids(t), ['b']);
    });

    test('an unknown experiment name is an error', () async {
      final t = tracker(config: const WatchConfig(experimentNames: ['nope']));
      await expectLater(t.poll(), throwsA(isA<MlflowException>()));
    });

    test('user filter', () async {
      server
        ..add(FakeRun('a', startTime: minutes(10)))
        ..add(FakeRun('b', startTime: minutes(10), user: 'bob'));
      final t = tracker(config: const WatchConfig(user: "bob'"));
      await t.poll();
      expect(ids(t), ['b']);
      expect(server.filters.first, "attributes.status = 'RUNNING' AND tags.`mlflow.user` = 'bob'");
    });
  });

  test('a steady poll costs two small searches', () async {
    server.add(FakeRun('a', startTime: minutes(10)));
    final t = tracker();
    await t.poll();
    server.requests.clear();
    now = now.add(const Duration(seconds: 2));
    await t.poll();
    expect(server.requests, ['runs/search', 'runs/search']);
  });
}
