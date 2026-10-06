// Runs mlwatcher's client and tracker against a real MLflow server.
//
// Skipped unless MLWATCHER_TEST_SERVER is set, e.g.
//   mlflow server --port 5055 &
//   MLWATCHER_TEST_SERVER=http://127.0.0.1:5055 flutter test test/integration
//
// It creates an experiment and a few runs on that server (use a scratch one).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:mlwatcher/src/domain/run_tracker.dart';
import 'package:mlwatcher/src/mlflow/mlflow_client.dart';
import 'package:mlwatcher/src/mlflow/mlflow_models.dart';

void main() {
  final url = Platform.environment['MLWATCHER_TEST_SERVER'];

  Future<Map<String, Object?>> call(String endpoint, Map<String, Object?> body) async {
    final res = await http.post(
      Uri.parse('$url/api/2.0/mlflow/$endpoint'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(body),
    );
    if (res.statusCode != 200) throw StateError('$endpoint: ${res.statusCode} ${res.body}');
    return (jsonDecode(res.body) as Map).cast<String, Object?>();
  }

  Future<String> createRun(String experimentId, String name, {required int start, String user = 'alice'}) async {
    final j = await call('runs/create', {
      'experiment_id': experimentId,
      'run_name': name,
      'start_time': start,
      'tags': [
        {'key': 'mlflow.user', 'value': user},
      ],
    });
    return ((j['run']! as Map)['info']! as Map)['run_id']! as String;
  }

  Future<void> setStatus(String runId, String status) =>
      call('runs/update', {'run_id': runId, 'status': status, 'end_time': DateTime.now().millisecondsSinceEpoch});

  test('tracks runs on a real MLflow server', () async {
    final experimentName = 'mlwatcher-it-${DateTime.now().millisecondsSinceEpoch}';
    final experimentId = (await call('experiments/create', {'name': experimentName}))['experiment_id']! as String;
    final now = DateTime.now().millisecondsSinceEpoch;

    final running = await createRun(experimentId, 'running', start: now - 600000);
    await call('runs/log-parameter', {'run_id': running, 'key': 'epochs', 'value': '50'});
    await call('runs/log-metric', {'run_id': running, 'key': 'epoch', 'value': 12, 'timestamp': now, 'step': 12});
    final failedAfter = await createRun(experimentId, 'failed-after', start: now - 300000);
    await setStatus(failedAfter, 'FAILED');
    final killed = await createRun(experimentId, 'killed', start: now - 200000);
    await setStatus(killed, 'KILLED');
    final failedBefore = await createRun(experimentId, 'failed-before', start: now - 900000);
    await setStatus(failedBefore, 'FAILED');
    final finished = await createRun(experimentId, 'finished', start: now - 100000);
    await setStatus(finished, 'FINISHED');
    final otherUser = await createRun(experimentId, 'bob-run', start: now - 50000, user: 'bob');

    final client = MlflowClient(MlflowConnection(baseUrl: url!));
    final tracker = RunTracker(
      client: client,
      config: WatchConfig(experimentNames: [experimentName], user: 'alice'),
    );

    expect(await tracker.poll(), isEmpty);
    final byName = {for (final r in tracker.runs) r.name: r};
    expect(byName.keys.toSet(), {'running', 'failed-after', 'killed'});
    expect(byName['running']!.epoch, 12);
    expect(byName['running']!.totalEpochs, 50);
    expect(byName['running']!.progress, closeTo(0.24, 1e-9));
    expect(byName['running']!.experimentName, experimentName);
    expect(byName['killed']!.status, MlflowStatus.killed);

    // The running run fails; a new run starts and dies between two polls.
    await setStatus(running, 'FAILED');
    final quick = await createRun(experimentId, 'quick', start: DateTime.now().millisecondsSinceEpoch);
    await setStatus(quick, 'FAILED');
    final events = await tracker.poll();
    expect({for (final e in events) e.run.name}, {'running', 'quick'});
    expect(tracker.runs.firstWhere((r) => r.name == 'running').status, MlflowStatus.failed);

    // Deleted on the server: disappears.
    final doomed = await createRun(experimentId, 'doomed', start: DateTime.now().millisecondsSinceEpoch);
    await tracker.poll();
    expect(tracker.runs.any((r) => r.id == doomed), isTrue);
    await call('runs/delete', {'run_id': doomed});
    await tracker.poll();
    expect(tracker.runs.any((r) => r.id == doomed), isFalse);

    expect(otherUser, isNotEmpty);
    expect(failedBefore, isNotEmpty);
    expect(finished, isNotEmpty);
    client.close();
  }, skip: url == null ? 'Set MLWATCHER_TEST_SERVER to run' : false);
}
