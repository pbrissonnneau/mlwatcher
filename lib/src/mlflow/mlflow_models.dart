/// MLflow run status (`RunStatus` in the REST API).
enum MlflowStatus {
  running,
  scheduled,
  finished,
  failed,
  killed,
  unknown;

  static MlflowStatus parse(Object? value) => switch (value) {
    'RUNNING' => running,
    'SCHEDULED' => scheduled,
    'FINISHED' => finished,
    'FAILED' => failed,
    'KILLED' => killed,
    _ => unknown,
  };

  /// Still in progress (scheduled runs are treated like running ones).
  bool get isActive => this == running || this == scheduled;

  /// Ended badly: failed or killed.
  bool get isFailure => this == failed || this == killed;
}

class MlflowExperiment {
  const MlflowExperiment({required this.id, required this.name});

  final String id;
  final String name;

  factory MlflowExperiment.fromJson(Map<String, Object?> j) =>
      MlflowExperiment(id: '${j['experiment_id']}', name: j['name'] as String? ?? '');
}

/// The few fields mlwatcher keeps from an MLflow run. Everything else the
/// API returns (other params, metrics, tags) is discarded while parsing.
class MlflowRun {
  const MlflowRun({
    required this.id,
    required this.name,
    required this.experimentId,
    required this.status,
    required this.startTime,
    this.endTime,
    this.deleted = false,
    this.epoch,
    this.totalEpochs,
    this.lastActivity,
  });

  final String id;
  final String name;
  final String experimentId;
  final MlflowStatus status;

  /// Milliseconds since epoch (server clock).
  final int startTime;
  final int? endTime;
  final bool deleted;

  /// Latest value of the configured epoch metric.
  final double? epoch;

  /// Value of the configured "total epochs" parameter.
  final double? totalEpochs;

  /// Most recent metric timestamp (ms), i.e. the last sign of life.
  final int? lastActivity;

  /// Parses a `Run` object, keeping only [epochMetric] and [totalEpochsParam].
  factory MlflowRun.fromJson(Map<String, Object?> j, {required String epochMetric, required String totalEpochsParam}) {
    final info = (j['info'] as Map?)?.cast<String, Object?>() ?? const {};
    final data = (j['data'] as Map?)?.cast<String, Object?>() ?? const {};
    double? epoch;
    int? lastActivity;
    for (final m in (data['metrics'] as List?) ?? const []) {
      if (m is! Map) continue;
      final ts = _int(m['timestamp']);
      if (ts != null && (lastActivity == null || ts > lastActivity)) lastActivity = ts;
      if (m['key'] == epochMetric) epoch = _double(m['value']);
    }
    double? total;
    for (final p in (data['params'] as List?) ?? const []) {
      if (p is Map && p['key'] == totalEpochsParam) total = _double(p['value']);
    }
    var name = info['run_name'] as String?;
    if (name == null || name.isEmpty) {
      // MLflow < 1.29 only stores the name as a tag.
      for (final t in (data['tags'] as List?) ?? const []) {
        if (t is Map && t['key'] == 'mlflow.runName') name = t['value'] as String?;
      }
    }
    final id = (info['run_id'] ?? info['run_uuid'] ?? '') as String;
    return MlflowRun(
      id: id,
      name: (name == null || name.isEmpty) ? id : name,
      experimentId: '${info['experiment_id'] ?? ''}',
      status: MlflowStatus.parse(info['status']),
      startTime: _int(info['start_time']) ?? 0,
      endTime: _int(info['end_time']),
      deleted: info['lifecycle_stage'] == 'deleted',
      epoch: epoch,
      totalEpochs: total,
      lastActivity: lastActivity,
    );
  }

  static int? _int(Object? v) => v is num ? v.toInt() : (v is String ? int.tryParse(v) : null);

  static double? _double(Object? v) {
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v.trim());
    return null;
  }
}
