import 'dart:convert';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mlwatcher/src/data/settings.dart';
import 'package:mlwatcher/src/domain/watched_run.dart';
import 'package:mlwatcher/src/mlflow/mlflow_client.dart';
import 'package:mlwatcher/src/mlflow/mlflow_models.dart';
import 'package:mlwatcher/src/ui/format.dart';

void main() {
  group('MlflowRun.fromJson', () {
    test('keeps only the configured metric and parameter', () {
      final r = MlflowRun.fromJson(
        {
          'info': {'run_id': 'x', 'run_name': 'train', 'experiment_id': '3', 'status': 'RUNNING', 'start_time': 1000},
          'data': {
            'metrics': [
              {'key': 'ep', 'value': 4.0, 'timestamp': 5000},
              {'key': 'loss', 'value': 0.1, 'timestamp': 7000},
            ],
            'params': [
              {'key': 'max_epochs', 'value': '20'},
            ],
          },
        },
        epochMetric: 'ep',
        totalEpochsParam: 'max_epochs',
      );
      expect((r.id, r.name, r.experimentId, r.status), ('x', 'train', '3', MlflowStatus.running));
      expect((r.epoch, r.totalEpochs, r.lastActivity), (4.0, 20.0, 7000));
    });

    test('falls back to the runName tag (old servers) then to the id', () {
      Map<String, Object?> run(List<Object?> tags) => {
        'info': {'run_uuid': 'u1', 'experiment_id': 1, 'status': 'FAILED', 'start_time': '10'},
        'data': {'tags': tags},
      };
      final withTag = MlflowRun.fromJson(
        run([
          {'key': 'mlflow.runName', 'value': 'legacy'},
        ]),
        epochMetric: 'epoch',
        totalEpochsParam: 'epochs',
      );
      expect((withTag.id, withTag.name, withTag.experimentId, withTag.startTime), ('u1', 'legacy', '1', 10));
      expect(MlflowRun.fromJson(run([]), epochMetric: 'epoch', totalEpochsParam: 'epochs').name, 'u1');
    });
  });

  group('MlflowClient', () {
    test('sends auth headers and maps errors', () async {
      late http.Request seen;
      final client = MlflowClient(
        const MlflowConnection(baseUrl: 'https://m.lan/', authMode: AuthMode.basic, username: 'u', secret: 'p'),
        httpClient: MockClient((req) async {
          seen = req;
          return http.Response('{"error_code":"UNAUTHENTICATED"}', 401);
        }),
      );
      await expectLater(
        client.searchExperiments(),
        throwsA(isA<MlflowException>().having((e) => e.message, 'message', contains('Authentication failed'))),
      );
      expect(seen.url.toString(), 'https://m.lan/api/2.0/mlflow/experiments/search');
      expect(seen.headers['Authorization'], 'Basic ${base64Encode(utf8.encode('u:p'))}');
    });

    test('bearer token and non-MLflow answers', () async {
      late http.Request seen;
      final client = MlflowClient(
        const MlflowConnection(baseUrl: 'http://m', authMode: AuthMode.token, secret: 'tok'),
        httpClient: MockClient((req) async {
          seen = req;
          return http.Response('<html>proxy login</html>', 200);
        }),
      );
      await expectLater(client.searchExperiments(), throwsA(isA<MlflowException>()));
      expect(seen.headers['Authorization'], 'Bearer tok');
    });

    test('follows pagination', () async {
      var calls = 0;
      final client = MlflowClient(
        const MlflowConnection(baseUrl: 'http://m'),
        httpClient: MockClient((req) async {
          calls++;
          final token = (jsonDecode(req.body) as Map)['page_token'];
          return http.Response(
            jsonEncode({
              'experiments': [
                {'experiment_id': token == null ? '1' : '2', 'name': 'e'},
              ],
              if (token == null) 'next_page_token': 'p2',
            }),
            200,
          );
        }),
      );
      expect([for (final e in await client.searchExperiments()) e.id], ['1', '2']);
      expect(calls, 2);
    });

    test('rejects an empty or invalid URL without a request', () async {
      final client = MlflowClient(
        const MlflowConnection(baseUrl: 'not a url'),
        httpClient: MockClient((_) async => fail('no request expected')),
      );
      await expectLater(client.searchExperiments(), throwsA(isA<MlflowException>()));
    });

    test('run page link', () {
      expect(
        const MlflowConnection(baseUrl: 'http://m:5000/').runPage('3', 'abc').toString(),
        'http://m:5000/#/experiments/3/runs/abc',
      );
    });
  });

  group('WatchedRun', () {
    WatchedRun run({MlflowStatus status = MlflowStatus.running, int? lastActivity, double? epoch, double? total}) =>
        WatchedRun(
          id: 'a',
          name: 'a',
          experimentId: '1',
          experimentName: 'e',
          status: status,
          startTime: 0,
          endTime: status.isActive ? null : 60000,
          lastActivity: lastActivity,
          epoch: epoch,
          totalEpochs: total,
        );
    final now = DateTime.fromMillisecondsSinceEpoch(40 * 60000);
    const stale = Duration(minutes: 30);

    test('indicator', () {
      expect(run(lastActivity: 20 * 60000).indicator(now, stale), RunIndicator.running);
      expect(run().indicator(now, stale), RunIndicator.stale);
      expect(run(status: MlflowStatus.finished).indicator(now, stale), RunIndicator.finished);
      expect(run(status: MlflowStatus.killed).indicator(now, stale), RunIndicator.failed);
      expect(run(status: MlflowStatus.failed).indicator(now, stale), RunIndicator.failed);
    });

    test('progress and duration', () {
      expect(run(epoch: 5).progress, isNull);
      expect(run(epoch: 15, total: 10).progress, 1.0);
      expect(run().duration(now), const Duration(minutes: 40));
      expect(run(status: MlflowStatus.finished).duration(now), const Duration(minutes: 1));
    });

    test('JSON round trip', () {
      final r = run(epoch: 2, total: 9, lastActivity: 5);
      final back = WatchedRun.fromJson(jsonDecode(jsonEncode(r.toJson())))!;
      expect(back.toJson(), r.toJson());
      expect(WatchedRun.fromJson({'id': 1}), isNull);
    });
  });

  test('Settings JSON round trip and tolerant parsing', () {
    const s = Settings(
      serverUrl: 'http://m',
      authMode: AuthMode.token,
      experimentNames: ['a', 'b'],
      staleMinutes: 12,
      opacityPercent: 70,
      alwaysOnTop: false,
      autoGrowOverlay: true,
      overlayBounds: Rect.fromLTWH(10, 20, 300, 200),
    );
    final back = Settings.fromJson(jsonDecode(jsonEncode(s.toJson())) as Map<String, Object?>);
    expect(back.toJson(), s.toJson());
    final garbage = Settings.fromJson({'authMode': 'zzz', 'opacityPercent': 5, 'experimentNames': 'x'});
    expect((garbage.authMode, garbage.opacityPercent), (AuthMode.none, 20));
    expect(garbage.experimentNames, isEmpty);
  });

  test('formatting', () {
    expect(formatDuration(const Duration(hours: 2, minutes: 5)), '2h 05m');
    expect(formatDuration(const Duration(minutes: 7, seconds: 3)), '7m');
    expect(formatDuration(const Duration(days: 1, hours: 3)), '1d 3h');
    expect(formatNumber(12), '12');
    expect(formatNumber(2.5), '2.5');
  });
}
