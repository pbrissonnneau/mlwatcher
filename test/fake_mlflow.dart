import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mlwatcher/src/mlflow/mlflow_client.dart';

/// A run on the fake server.
class FakeRun {
  FakeRun(
    this.id, {
    this.experimentId = '1',
    this.status = 'RUNNING',
    required this.startTime,
    this.endTime,
    this.epoch,
    this.totalEpochs,
    this.metricTime,
    this.user = 'alice',
    this.deleted = false,
  });

  final String id;
  String experimentId;
  String status;
  int startTime;
  int? endTime;
  double? epoch;
  String? totalEpochs;
  int? metricTime;
  String user;
  bool deleted;

  Map<String, Object?> toJson() => {
    'info': {
      'run_id': id,
      'run_uuid': id,
      'run_name': 'run-$id',
      'experiment_id': experimentId,
      'status': status,
      'start_time': startTime,
      'end_time': ?endTime,
      'lifecycle_stage': deleted ? 'deleted' : 'active',
    },
    'data': {
      'metrics': [
        if (epoch != null) {'key': 'epoch', 'value': epoch, 'timestamp': metricTime ?? startTime, 'step': 0},
        {'key': 'loss', 'value': 0.5, 'timestamp': metricTime ?? startTime, 'step': 0},
      ],
      'params': [
        if (totalEpochs != null) {'key': 'epochs', 'value': totalEpochs},
        {'key': 'lr', 'value': '0.001'},
      ],
      'tags': [
        {'key': 'mlflow.user', 'value': user},
        {'key': 'mlflow.source.name', 'value': 'train.py'},
      ],
    },
  };
}

/// In-memory MLflow REST server understanding the filters mlwatcher sends.
class FakeMlflow {
  final experiments = <String, String>{'1': 'resnet', '2': 'bert'};
  final runs = <String, FakeRun>{};
  final requests = <String>[];
  final filters = <String>[];
  bool down = false;
  int? httpError;

  void add(FakeRun r) => runs[r.id] = r;

  MlflowClient client() =>
      MlflowClient(const MlflowConnection(baseUrl: 'http://mlflow.test:5000/'), httpClient: MockClient(_handle));

  Future<http.Response> _handle(http.Request req) async {
    if (down) throw http.ClientException('Connection refused');
    if (httpError != null) return http.Response('{"error_code":"X","message":"boom"}', httpError!);
    final path = req.url.path.replaceFirst('/api/2.0/mlflow/', '');
    requests.add(path);
    switch (path) {
      case 'experiments/search':
        return _json({
          'experiments': [
            for (final MapEntry(:key, :value) in experiments.entries) {'experiment_id': key, 'name': value},
          ],
        });
      case 'runs/search':
        final body = jsonDecode(req.body) as Map<String, Object?>;
        final ids = (body['experiment_ids']! as List).cast<String>().toSet();
        final filter = body['filter']! as String;
        filters.add(filter);
        final matches = runs.values.where((r) => !r.deleted && ids.contains(r.experimentId) && _matches(r, filter));
        return _json({
          'runs': [for (final r in matches) r.toJson()],
        });
      case 'runs/get':
        final r = runs[req.url.queryParameters['run_id']];
        if (r == null) {
          return http.Response('{"error_code":"RESOURCE_DOES_NOT_EXIST","message":"Run not found"}', 404);
        }
        return _json({'run': r.toJson()});
    }
    return http.Response('not found', 404);
  }

  static bool _matches(FakeRun r, String filter) {
    for (final clause in filter.split(' AND ')) {
      final status = RegExp(r"attributes\.status = '(\w+)'").firstMatch(clause);
      if (status != null && r.status != status.group(1)) return false;
      final notStatus = RegExp(r"attributes\.status != '(\w+)'").firstMatch(clause);
      if (notStatus != null && r.status == notStatus.group(1)) return false;
      final since = RegExp(r'attributes\.start_time >= (\d+)').firstMatch(clause);
      if (since != null && r.startTime < int.parse(since.group(1)!)) return false;
      final user = RegExp(r"tags\.`mlflow\.user` = '([^']*)'").firstMatch(clause);
      if (user != null && r.user != user.group(1)) return false;
    }
    return true;
  }

  static http.Response _json(Object j) =>
      http.Response(jsonEncode(j), 200, headers: {'content-type': 'application/json'});
}
