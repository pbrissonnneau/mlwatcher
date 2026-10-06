import '../mlflow/mlflow_client.dart';
import '../mlflow/mlflow_models.dart';
import 'watched_run.dart';

/// What to watch on the server.
class WatchConfig {
  const WatchConfig({
    this.experimentNames = const [],
    this.user = '',
    this.epochMetric = 'epoch',
    this.totalEpochsParam = 'epochs',
  });

  final List<String> experimentNames;
  final String user;
  final String epochMetric;
  final String totalEpochsParam;
}

/// A run seen going from running to finished / failed / killed.
class RunEnded {
  const RunEnded(this.run);
  final WatchedRun run;
}

/// Decides which runs are shown, from successive polls of the server.
///
/// * Every running run is shown.
/// * On the first successful poll, failed/killed runs started after the
///   oldest running run are added too.
/// * Afterwards, a run that fails is kept (also one that started and died
///   between two polls).
/// * A run stays, whatever its status, until [dismiss] is called.
///
/// [poll] fetches everything first and only then updates the state, so a
/// failing request never leaves a half-applied update.
class RunTracker {
  RunTracker({
    required this.client,
    required this.config,
    DateTime Function()? now,
    Iterable<WatchedRun> runs = const [],
    Map<String, int> dismissed = const {},
  }) : _now = now ?? DateTime.now,
       _runs = {for (final r in runs) r.id: r},
       _dismissed = Map.of(dismissed);

  final MlflowClient client;
  final WatchConfig config;
  final DateTime Function() _now;

  final Map<String, WatchedRun> _runs;

  /// Dismissed run id -> last time (ms) it was still relevant.
  final Map<String, int> _dismissed;

  Map<String, String>? _experimentNames;
  List<String> _watchedExperimentIds = const [];
  DateTime? _experimentsFetchedAt;

  /// Local time of the last successful poll; null before the first one.
  DateTime? _lastSuccess;

  static const experimentsRefresh = Duration(minutes: 1);

  /// Overlap when looking for runs that started and failed between polls
  /// (absorbs small clock differences with the server).
  static const recentOverlap = Duration(minutes: 1);

  /// Look-back limit after a long disconnection.
  static const maxCatchUp = Duration(hours: 24);

  /// Dismissed ids are forgotten once irrelevant for this long.
  static const dismissedRetention = Duration(days: 7);

  /// Shown runs, newest first.
  List<WatchedRun> get runs => _runs.values.toList()..sort((a, b) => b.startTime.compareTo(a.startTime));

  Map<String, int> get dismissed => Map.unmodifiable(_dismissed);

  bool get hasPolled => _lastSuccess != null;

  void dismiss(String runId) {
    if (_runs.remove(runId) != null) _dismissed[runId] = _now().millisecondsSinceEpoch;
  }

  /// One polling round. Throws [MlflowException] when the server cannot be
  /// queried; the state is then unchanged.
  Future<List<RunEnded>> poll() async {
    final now = _now();
    final firstPoll = _lastSuccess == null;
    await _refreshExperiments(now);
    final ids = _watchedExperimentIds;

    // ---- Fetch ----
    final running = ids.isEmpty ? const <MlflowRun>[] : await _search(ids, "attributes.status = 'RUNNING'");
    final runningIds = {for (final r in running) r.id};

    var extra = const <MlflowRun>[];
    if (ids.isNotEmpty) {
      if (firstPoll) {
        // Failures that happened while the oldest current run was going on.
        if (running.isNotEmpty) {
          final oldest = running.map((r) => r.startTime).reduce((a, b) => a < b ? a : b);
          extra = [
            for (final status in const ['FAILED', 'KILLED'])
              ...await _search(ids, "attributes.status = '$status' AND attributes.start_time >= $oldest"),
          ];
        }
      } else {
        // Runs started since the previous poll: catches runs that failed
        // before ever being seen running.
        var since = _lastSuccess!.subtract(recentOverlap);
        final floor = now.subtract(maxCatchUp);
        if (since.isBefore(floor)) since = floor;
        extra = await _search(
          ids,
          "attributes.start_time >= ${since.millisecondsSinceEpoch} AND attributes.status != 'RUNNING'",
        );
      }
    }
    final extraById = {for (final r in extra) r.id: r};

    // Shown runs that stopped running: fetch their final state.
    final ended = <String, MlflowRun?>{};
    for (final run in _runs.values) {
      if (!run.status.isActive || runningIds.contains(run.id)) continue;
      final known = extraById[run.id];
      if (known != null) {
        ended[run.id] = known;
        continue;
      }
      try {
        ended[run.id] = await client.getRun(
          run.id,
          epochMetric: config.epochMetric,
          totalEpochsParam: config.totalEpochsParam,
        );
      } on MlflowException catch (e) {
        if (!e.notFound) rethrow;
        ended[run.id] = null; // Deleted on the server.
      }
    }

    // ---- Apply ----
    final events = <RunEnded>[];
    final nowMs = now.millisecondsSinceEpoch;
    for (final r in running) {
      if (_dismissed.containsKey(r.id)) {
        _dismissed[r.id] = nowMs; // Still running: keep it hidden.
      } else {
        _runs[r.id] = _toWatched(r);
      }
    }
    for (final MapEntry(key: id, value: r) in ended.entries) {
      if (r == null || r.deleted) {
        _runs.remove(id);
        continue;
      }
      final w = _toWatched(r);
      _runs[id] = w;
      if (!r.status.isActive && !firstPoll) events.add(RunEnded(w));
    }
    for (final r in extra) {
      if (!r.status.isFailure || r.deleted || _runs.containsKey(r.id) || _dismissed.containsKey(r.id)) continue;
      final w = _toWatched(r);
      _runs[r.id] = w;
      if (!firstPoll) events.add(RunEnded(w));
    }
    _dismissed.removeWhere((_, t) => nowMs - t > dismissedRetention.inMilliseconds);
    _lastSuccess = now;
    return events;
  }

  WatchedRun _toWatched(MlflowRun r) => WatchedRun.from(r, _experimentNames?[r.experimentId] ?? '');

  Future<List<MlflowRun>> _search(List<String> ids, String filter) => client.searchRuns(
    experimentIds: ids,
    filter: '$filter$_userClause',
    epochMetric: config.epochMetric,
    totalEpochsParam: config.totalEpochsParam,
  );

  String get _userClause {
    // MLflow filters have no escaping: quotes are simply not allowed.
    final user = config.user.trim().replaceAll(RegExp('[\'"`]'), '');
    return user.isEmpty ? '' : " AND tags.`mlflow.user` = '$user'";
  }

  Future<void> _refreshExperiments(DateTime now) async {
    final fetched = _experimentsFetchedAt;
    if (_experimentNames != null && fetched != null && now.difference(fetched) < experimentsRefresh) return;
    final all = await client.searchExperiments();
    final wanted = {
      for (final n in config.experimentNames.map((n) => n.trim()))
        if (n.isNotEmpty) n,
    };
    final ids = [
      for (final e in all)
        if (wanted.isEmpty || wanted.contains(e.name)) e.id,
    ];
    if (wanted.isNotEmpty && ids.isEmpty) {
      throw MlflowException('No experiment named ${wanted.map((n) => '"$n"').join(', ')}');
    }
    _experimentNames = {for (final e in all) e.id: e.name};
    _watchedExperimentIds = ids;
    _experimentsFetchedAt = now;
  }
}
