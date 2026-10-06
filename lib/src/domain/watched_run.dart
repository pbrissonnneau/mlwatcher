import '../mlflow/mlflow_models.dart';

/// What the overlay shows for a run.
enum RunIndicator { running, stale, finished, failed }

/// A run shown in the overlay until the user dismisses it.
class WatchedRun {
  const WatchedRun({
    required this.id,
    required this.name,
    required this.experimentId,
    required this.experimentName,
    required this.status,
    required this.startTime,
    this.endTime,
    this.epoch,
    this.totalEpochs,
    this.lastActivity,
  });

  final String id;
  final String name;
  final String experimentId;
  final String experimentName;
  final MlflowStatus status;
  final int startTime;
  final int? endTime;
  final double? epoch;
  final double? totalEpochs;
  final int? lastActivity;

  factory WatchedRun.from(MlflowRun r, String experimentName) => WatchedRun(
    id: r.id,
    name: r.name,
    experimentId: r.experimentId,
    experimentName: experimentName,
    status: r.status,
    startTime: r.startTime,
    endTime: r.endTime,
    epoch: r.epoch,
    totalEpochs: r.totalEpochs,
    lastActivity: r.lastActivity,
  );

  /// Last sign of life: newest metric, or the start of the run.
  int get lastSeenAlive => (lastActivity != null && lastActivity! > startTime) ? lastActivity! : startTime;

  RunIndicator indicator(DateTime now, Duration staleAfter) {
    if (status.isFailure) return RunIndicator.failed;
    if (status.isActive) {
      final idle = now.millisecondsSinceEpoch - lastSeenAlive;
      return idle > staleAfter.inMilliseconds ? RunIndicator.stale : RunIndicator.running;
    }
    return RunIndicator.finished;
  }

  /// Progress in [0, 1], or null when the epoch or the total is unknown.
  double? get progress {
    final e = epoch, t = totalEpochs;
    if (e == null || t == null || t <= 0) return null;
    return (e / t).clamp(0.0, 1.0);
  }

  Duration duration(DateTime now) {
    final end = (status.isActive || endTime == null) ? now.millisecondsSinceEpoch : endTime!;
    final ms = end - startTime;
    return Duration(milliseconds: ms < 0 ? 0 : ms);
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'experimentId': experimentId,
    'experimentName': experimentName,
    'status': status.name,
    'startTime': startTime,
    'endTime': ?endTime,
    'epoch': ?epoch,
    'totalEpochs': ?totalEpochs,
    'lastActivity': ?lastActivity,
  };

  static WatchedRun? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'], start = json['startTime'];
    if (id is! String || start is! num) return null;
    return WatchedRun(
      id: id,
      name: json['name'] as String? ?? id,
      experimentId: json['experimentId'] as String? ?? '',
      experimentName: json['experimentName'] as String? ?? '',
      status: MlflowStatus.values.asNameMap()[json['status']] ?? MlflowStatus.unknown,
      startTime: start.toInt(),
      endTime: (json['endTime'] as num?)?.toInt(),
      epoch: (json['epoch'] as num?)?.toDouble(),
      totalEpochs: (json['totalEpochs'] as num?)?.toDouble(),
      lastActivity: (json['lastActivity'] as num?)?.toInt(),
    );
  }
}
