import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'mlflow_models.dart';

enum AuthMode { none, basic, token }

/// Connection parameters of an MLflow tracking server.
class MlflowConnection {
  const MlflowConnection({
    required this.baseUrl,
    this.authMode = AuthMode.none,
    this.username = '',
    this.secret = '',
    this.allowUntrustedCertificate = false,
  });

  /// e.g. `http://mlflow.lan:5000` (any trailing slash is ignored).
  final String baseUrl;
  final AuthMode authMode;
  final String username;

  /// Password (basic) or token (bearer).
  final String secret;

  /// Accept a self-signed / private-CA certificate for this host only.
  final bool allowUntrustedCertificate;

  String get normalizedBaseUrl => baseUrl.trim().replaceAll(RegExp(r'/+$'), '');

  /// Link to a run in the MLflow web UI.
  Uri runPage(String experimentId, String runId) =>
      Uri.parse('$normalizedBaseUrl/#/experiments/$experimentId/runs/$runId');

  Map<String, String> get authHeaders => switch (authMode) {
    AuthMode.none => const {},
    AuthMode.basic => {'Authorization': 'Basic ${base64Encode(utf8.encode('$username:$secret'))}'},
    AuthMode.token => {'Authorization': 'Bearer $secret'},
  };
}

class MlflowException implements Exception {
  const MlflowException(this.message, {this.statusCode, this.errorCode});
  final String message;
  final int? statusCode;
  final String? errorCode;

  bool get notFound => statusCode == 404 || errorCode == 'RESOURCE_DOES_NOT_EXIST';

  @override
  String toString() => message;
}

/// Minimal client for the MLflow REST API (`/api/2.0/mlflow/...`).
class MlflowClient {
  MlflowClient(this.connection, {http.Client? httpClient, this.timeout = const Duration(seconds: 8)})
    : _http = httpClient ?? _defaultClient(connection);

  final MlflowConnection connection;
  final Duration timeout;
  final http.Client _http;

  static http.Client _defaultClient(MlflowConnection c) {
    final io = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    if (c.allowUntrustedCertificate) {
      final host = Uri.tryParse(c.normalizedBaseUrl)?.host;
      io.badCertificateCallback = (cert, h, port) => h == host;
    }
    return IOClient(io);
  }

  /// All active experiments.
  Future<List<MlflowExperiment>> searchExperiments() async {
    final result = <MlflowExperiment>[];
    String? pageToken;
    do {
      final j = await _post('experiments/search', {
        'max_results': 1000,
        'view_type': 'ACTIVE_ONLY',
        'page_token': ?pageToken,
      });
      for (final e in (j['experiments'] as List?) ?? const []) {
        if (e is Map) result.add(MlflowExperiment.fromJson(e.cast<String, Object?>()));
      }
      pageToken = _nextToken(j);
    } while (pageToken != null);
    return result;
  }

  /// Runs of [experimentIds] matching [filter] (MLflow search syntax).
  Future<List<MlflowRun>> searchRuns({
    required List<String> experimentIds,
    required String filter,
    required String epochMetric,
    required String totalEpochsParam,
    int maxResults = 1000,
  }) async {
    final result = <MlflowRun>[];
    // Keep request bodies reasonable on servers with many experiments.
    for (var i = 0; i < experimentIds.length; i += 100) {
      final ids = experimentIds.sublist(i, i + 100 > experimentIds.length ? experimentIds.length : i + 100);
      String? pageToken;
      do {
        final j = await _post('runs/search', {
          'experiment_ids': ids,
          'filter': filter,
          'run_view_type': 'ACTIVE_ONLY',
          'max_results': maxResults,
          'order_by': ['attributes.start_time DESC'],
          'page_token': ?pageToken,
        });
        for (final r in (j['runs'] as List?) ?? const []) {
          if (r is Map) {
            result.add(
              MlflowRun.fromJson(
                r.cast<String, Object?>(),
                epochMetric: epochMetric,
                totalEpochsParam: totalEpochsParam,
              ),
            );
          }
        }
        pageToken = _nextToken(j);
      } while (pageToken != null);
    }
    return result;
  }

  /// One run by id. Throws [MlflowException] with `notFound` when it no longer exists.
  Future<MlflowRun> getRun(String runId, {required String epochMetric, required String totalEpochsParam}) async {
    final j = await _get('runs/get', {'run_id': runId});
    final run = (j['run'] as Map?)?.cast<String, Object?>();
    if (run == null) throw const MlflowException('Malformed runs/get response');
    return MlflowRun.fromJson(run, epochMetric: epochMetric, totalEpochsParam: totalEpochsParam);
  }

  static String? _nextToken(Map<String, Object?> j) {
    final t = j['next_page_token'];
    return t is String && t.isNotEmpty ? t : null;
  }

  Uri _uri(String endpoint, [Map<String, String>? query]) {
    final base = connection.normalizedBaseUrl;
    if (base.isEmpty) throw const MlflowException('No MLflow server configured');
    final uri = Uri.tryParse('$base/api/2.0/mlflow/$endpoint');
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      throw MlflowException('Invalid server URL: $base');
    }
    return query == null ? uri : uri.replace(queryParameters: query);
  }

  Future<Map<String, Object?>> _post(String endpoint, Map<String, Object?> body) => _send(
    () => _http.post(
      _uri(endpoint),
      headers: {...connection.authHeaders, 'Content-Type': 'application/json'},
      body: jsonEncode(body),
    ),
  );

  Future<Map<String, Object?>> _get(String endpoint, Map<String, String> query) =>
      _send(() => _http.get(_uri(endpoint, query), headers: connection.authHeaders));

  Future<Map<String, Object?>> _send(Future<http.Response> Function() request) async {
    final http.Response res;
    try {
      res = await request().timeout(timeout);
    } on MlflowException {
      rethrow;
    } on TimeoutException {
      throw const MlflowException('Server did not answer in time');
    } on HandshakeException catch (e) {
      throw MlflowException('TLS error: ${e.message}');
    } on SocketException catch (e) {
      throw MlflowException('Cannot reach server: ${e.osError?.message ?? e.message}');
    } on http.ClientException catch (e) {
      throw MlflowException('Cannot reach server: ${e.message}');
    }
    if (res.statusCode == 401 || res.statusCode == 403) {
      throw MlflowException('Authentication failed (HTTP ${res.statusCode})', statusCode: res.statusCode);
    }
    if (res.statusCode != 200) {
      var detail = '';
      String? code;
      try {
        final j = jsonDecode(res.body);
        if (j is Map) {
          if (j['message'] is String) detail = ': ${j['message']}';
          if (j['error_code'] is String) code = j['error_code'] as String;
        }
      } catch (_) {}
      throw MlflowException('HTTP ${res.statusCode}$detail', statusCode: res.statusCode, errorCode: code);
    }
    try {
      final j = jsonDecode(utf8.decode(res.bodyBytes));
      if (j is Map) return j.cast<String, Object?>();
    } catch (_) {}
    throw const MlflowException('Unexpected response (is this an MLflow server?)');
  }

  void close() => _http.close();
}
