import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/json_store.dart';
import '../data/secret_store.dart';
import '../data/settings.dart';
import '../domain/run_tracker.dart';
import '../domain/watched_run.dart';
import '../mlflow/mlflow_client.dart';
import '../mlflow/mlflow_models.dart';
import '../platform/notifier.dart';

/// Owns settings, the MLflow polling loop and the shown runs.
class WatcherService extends ChangeNotifier {
  WatcherService({
    required this.store,
    required this.secrets,
    this.notifier,
    this.pollInterval = const Duration(seconds: 2),
    MlflowClient Function(MlflowConnection)? clientFactory,
  }) : _clientFactory = clientFactory ?? MlflowClient.new;

  final JsonStore store;
  final SecretStore secrets;
  final Notifier? notifier;
  final Duration pollInterval;
  final MlflowClient Function(MlflowConnection) _clientFactory;

  Settings _settings = const Settings();
  String _secret = '';
  MlflowClient? _client;
  RunTracker? _tracker;
  String? _error;
  Timer? _timer;
  bool _polling = false;
  bool _disposed = false;
  int _generation = 0;
  String? _savedState;

  Settings get settings => _settings;
  String get secret => _secret;

  /// Last polling error; while set, no run is shown (they may be outdated).
  String? get error => _error;

  /// Runs to show, newest first (empty while [error] is set).
  List<WatchedRun> get runs => _error != null ? const [] : (_tracker?.runs ?? const []);

  bool get hasUndismissedFailure => runs.any((r) => r.status.isFailure);

  /// True until the first poll after start-up or a settings change answers.
  bool get loading => _settings.isConfigured && _error == null && !(_tracker?.hasPolled ?? false);

  Duration get staleAfter => Duration(minutes: _settings.staleMinutes);

  MlflowConnection get connection => _connectionFor(_settings, _secret);

  static MlflowConnection _connectionFor(Settings s, String secret) => MlflowConnection(
    baseUrl: s.serverUrl,
    authMode: s.authMode,
    username: s.username,
    secret: secret,
    allowUntrustedCertificate: s.allowUntrustedCertificate,
  );

  Future<void> load() async {
    _settings = await store.loadSettings();
    _secret = await secrets.read();
    final (runs, dismissed) = await store.loadState();
    _rebuildTracker(runs: runs, dismissed: dismissed);
  }

  void start() {
    _schedule(Duration.zero);
  }

  /// Saves display-only changes (opacity, on top, position...).
  Future<void> updateDisplay(Settings s) async {
    _settings = s;
    notifyListeners();
    await store.saveSettings(s);
  }

  /// Saves settings from the settings window and reconnects if needed.
  Future<void> applySettings(Settings s, String secret) async {
    final reconnect = s.watchesDifferentlyThan(_settings) || secret != _secret;
    _settings = s;
    await store.saveSettings(s);
    if (secret != _secret) {
      _secret = secret;
      await secrets.write(secret);
    }
    if (reconnect) {
      final t = _tracker;
      _rebuildTracker(runs: t?.runs ?? const [], dismissed: t?.dismissed ?? const {});
      _error = null;
      _schedule(Duration.zero);
    }
    notifyListeners();
  }

  /// Tries a connection without changing anything; returns null on success.
  Future<String?> testConnection(Settings s, String secret) async {
    final client = _clientFactory(_connectionFor(s, secret));
    try {
      final experiments = await client.searchExperiments();
      final wanted = s.experimentNames.toSet();
      final missing = wanted.difference({for (final e in experiments) e.name});
      if (missing.isNotEmpty) return 'Connected, but no experiment named: ${missing.join(', ')}';
      return null;
    } on MlflowException catch (e) {
      return e.message;
    } catch (e) {
      return '$e';
    } finally {
      client.close();
    }
  }

  void dismiss(String runId) {
    _tracker?.dismiss(runId);
    notifyListeners();
    unawaited(_saveState());
  }

  Future<void> openRun(WatchedRun run) async {
    try {
      await launchUrl(connection.runPage(run.experimentId, run.id));
    } catch (e) {
      debugPrint('Cannot open browser: $e');
    }
  }

  void _rebuildTracker({required List<WatchedRun> runs, required Map<String, int> dismissed}) {
    _generation++;
    _client?.close();
    _client = _settings.isConfigured ? _clientFactory(connection) : null;
    _tracker = _client == null
        ? null
        : RunTracker(
            client: _client!,
            config: WatchConfig(
              experimentNames: _settings.experimentNames,
              user: _settings.userFilter,
              epochMetric: _settings.epochMetric,
              totalEpochsParam: _settings.totalEpochsParam,
            ),
            runs: runs,
            dismissed: dismissed,
          );
    if (_tracker == null) _error = null;
  }

  void _schedule(Duration delay) {
    _timer?.cancel();
    if (_disposed) return;
    _timer = Timer(delay, _pollOnce);
  }

  /// One round; the next starts [pollInterval] after this one ends, so slow
  /// answers never pile up requests.
  Future<void> _pollOnce() async {
    if (_polling || _disposed) return;
    final tracker = _tracker;
    if (tracker == null) {
      _schedule(pollInterval);
      return;
    }
    _polling = true;
    final generation = _generation;
    try {
      final ended = await tracker.poll();
      if (generation != _generation || _disposed) return; // Settings changed meanwhile.
      _error = null;
      for (final e in ended) {
        _notifyEnded(e.run);
      }
      unawaited(_saveState());
    } on MlflowException catch (e) {
      if (generation == _generation) _error = e.message;
    } catch (e) {
      if (generation == _generation) _error = '$e';
    } finally {
      _polling = false;
      if (!_disposed) {
        notifyListeners();
        _schedule(generation == _generation ? pollInterval : Duration.zero);
      }
    }
  }

  void _notifyEnded(WatchedRun run) {
    final n = notifier;
    if (n == null) return;
    final failed = run.status.isFailure;
    if (failed ? !_settings.notifyOnFailure : !_settings.notifyOnFinish) return;
    final what = switch (run.status) {
      MlflowStatus.failed => 'failed',
      MlflowStatus.killed => 'was killed',
      _ => 'finished',
    };
    unawaited(
      n.show(
        title: 'Run $what: ${run.name}',
        body: run.experimentName.isEmpty ? 'MLflow' : 'Experiment: ${run.experimentName}',
        onClick: () => unawaited(openRun(run)),
      ),
    );
  }

  /// Persists the shown runs only when they changed (not every 2 seconds).
  Future<void> _saveState() async {
    final t = _tracker;
    if (t == null) return;
    final runs = t.runs, dismissed = t.dismissed;
    final encoded = jsonEncode([for (final r in runs) r.toJson(), dismissed]);
    if (encoded == _savedState) return;
    _savedState = encoded;
    try {
      await store.saveState(runs, dismissed);
    } catch (e) {
      debugPrint('Cannot save state: $e');
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _client?.close();
    super.dispose();
  }
}
