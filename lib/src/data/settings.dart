import 'dart:ui' show Rect;

import '../mlflow/mlflow_client.dart';

/// User settings, persisted as JSON (the secret is stored separately, see
/// `SecretStore`).
class Settings {
  const Settings({
    this.serverUrl = '',
    this.authMode = AuthMode.none,
    this.username = '',
    this.allowUntrustedCertificate = false,
    this.experimentNames = const [],
    this.userFilter = '',
    this.epochMetric = 'epoch',
    this.totalEpochsParam = 'epochs',
    this.staleMinutes = 30,
    this.opacityPercent = 90,
    this.alwaysOnTop = true,
    this.autoGrowOverlay = false,
    this.overlayVisible = true,
    this.notifyOnFinish = true,
    this.notifyOnFailure = true,
    this.overlayBounds,
  });

  final String serverUrl;
  final AuthMode authMode;
  final String username;
  final bool allowUntrustedCertificate;

  /// Experiments to watch by exact name; empty means all experiments.
  final List<String> experimentNames;

  /// Only runs of this user (`mlflow.user` tag); empty means everyone.
  final String userFilter;

  final String epochMetric;
  final String totalEpochsParam;

  /// A running run with no new metric for this long is shown orange.
  final int staleMinutes;

  final int opacityPercent;
  final bool alwaysOnTop;

  /// The overlay always shrinks to fit its runs; with this it also grows.
  final bool autoGrowOverlay;

  final bool overlayVisible;
  final bool notifyOnFinish;
  final bool notifyOnFailure;
  final Rect? overlayBounds;

  bool get isConfigured => serverUrl.trim().isNotEmpty;

  Settings copyWith({
    String? serverUrl,
    AuthMode? authMode,
    String? username,
    bool? allowUntrustedCertificate,
    List<String>? experimentNames,
    String? userFilter,
    String? epochMetric,
    String? totalEpochsParam,
    int? staleMinutes,
    int? opacityPercent,
    bool? alwaysOnTop,
    bool? autoGrowOverlay,
    bool? overlayVisible,
    bool? notifyOnFinish,
    bool? notifyOnFailure,
    Rect? overlayBounds,
  }) => Settings(
    serverUrl: serverUrl ?? this.serverUrl,
    authMode: authMode ?? this.authMode,
    username: username ?? this.username,
    allowUntrustedCertificate: allowUntrustedCertificate ?? this.allowUntrustedCertificate,
    experimentNames: experimentNames ?? this.experimentNames,
    userFilter: userFilter ?? this.userFilter,
    epochMetric: epochMetric ?? this.epochMetric,
    totalEpochsParam: totalEpochsParam ?? this.totalEpochsParam,
    staleMinutes: staleMinutes ?? this.staleMinutes,
    opacityPercent: opacityPercent ?? this.opacityPercent,
    alwaysOnTop: alwaysOnTop ?? this.alwaysOnTop,
    autoGrowOverlay: autoGrowOverlay ?? this.autoGrowOverlay,
    overlayVisible: overlayVisible ?? this.overlayVisible,
    notifyOnFinish: notifyOnFinish ?? this.notifyOnFinish,
    notifyOnFailure: notifyOnFailure ?? this.notifyOnFailure,
    overlayBounds: overlayBounds ?? this.overlayBounds,
  );

  /// Whether a change from [old] requires a new connection / fresh tracking.
  bool watchesDifferentlyThan(Settings old) =>
      serverUrl.trim() != old.serverUrl.trim() ||
      authMode != old.authMode ||
      username != old.username ||
      allowUntrustedCertificate != old.allowUntrustedCertificate ||
      experimentNames.join('\n') != old.experimentNames.join('\n') ||
      userFilter.trim() != old.userFilter.trim() ||
      epochMetric != old.epochMetric ||
      totalEpochsParam != old.totalEpochsParam;

  Map<String, Object?> toJson() => {
    'serverUrl': serverUrl,
    'authMode': authMode.name,
    'username': username,
    'allowUntrustedCertificate': allowUntrustedCertificate,
    'experimentNames': experimentNames,
    'userFilter': userFilter,
    'epochMetric': epochMetric,
    'totalEpochsParam': totalEpochsParam,
    'staleMinutes': staleMinutes,
    'opacityPercent': opacityPercent,
    'alwaysOnTop': alwaysOnTop,
    'autoGrowOverlay': autoGrowOverlay,
    'overlayVisible': overlayVisible,
    'notifyOnFinish': notifyOnFinish,
    'notifyOnFailure': notifyOnFailure,
    if (overlayBounds case final b?) 'overlayBounds': [b.left, b.top, b.width, b.height],
  };

  factory Settings.fromJson(Map<String, Object?> j) {
    const d = Settings();
    T read<T>(String key, T fallback) {
      final v = j[key];
      return v is T ? v : fallback;
    }

    Rect? bounds;
    final b = j['overlayBounds'];
    if (b is List && b.length == 4 && b.every((e) => e is num)) {
      final n = b.cast<num>().map((e) => e.toDouble()).toList();
      bounds = Rect.fromLTWH(n[0], n[1], n[2], n[3]);
    }
    return Settings(
      serverUrl: read('serverUrl', d.serverUrl),
      authMode: AuthMode.values.asNameMap()[j['authMode']] ?? d.authMode,
      username: read('username', d.username),
      allowUntrustedCertificate: read('allowUntrustedCertificate', d.allowUntrustedCertificate),
      experimentNames: (j['experimentNames'] is List)
          ? (j['experimentNames'] as List).whereType<String>().toList()
          : d.experimentNames,
      userFilter: read('userFilter', d.userFilter),
      epochMetric: read('epochMetric', d.epochMetric),
      totalEpochsParam: read('totalEpochsParam', d.totalEpochsParam),
      staleMinutes: read<num>('staleMinutes', d.staleMinutes).toInt().clamp(1, 10000),
      opacityPercent: read<num>('opacityPercent', d.opacityPercent).toInt().clamp(20, 100),
      alwaysOnTop: read('alwaysOnTop', d.alwaysOnTop),
      autoGrowOverlay: read('autoGrowOverlay', d.autoGrowOverlay),
      overlayVisible: read('overlayVisible', d.overlayVisible),
      notifyOnFinish: read('notifyOnFinish', d.notifyOnFinish),
      notifyOnFailure: read('notifyOnFailure', d.notifyOnFailure),
      overlayBounds: bounds,
    );
  }
}
