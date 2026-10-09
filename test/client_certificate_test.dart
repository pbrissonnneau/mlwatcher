import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mlwatcher/src/mlflow/mlflow_client.dart';

/// Mutual TLS against a local HTTPS server that answers only clients
/// presenting a certificate signed by the test CA.
///
/// test/certs holds a throwaway CA, a server certificate for 127.0.0.1 and a
/// client certificate (password `s3cret`), generated with openssl for these
/// tests only.
void main() {
  const certs = 'test/certs';
  late HttpServer server;
  late String baseUrl;
  String? seenClient;

  setUp(() async {
    seenClient = null;
    final context = SecurityContext()
      ..useCertificateChain('$certs/server.pem')
      ..usePrivateKey('$certs/server.key')
      ..setTrustedCertificates('$certs/ca.pem');
    server = await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, context, requestClientCertificate: true);
    baseUrl = 'https://127.0.0.1:${server.port}';
    server.listen((request) async {
      final cert = request.certificate;
      if (cert == null) {
        request.response.statusCode = HttpStatus.forbidden;
      } else {
        seenClient = cert.subject;
        request.response
          ..headers.contentType = ContentType.json
          ..write(
            jsonEncode({
              'experiments': [
                {'experiment_id': '1', 'name': 'exp', 'lifecycle_stage': 'active'},
              ],
            }),
          );
      }
      await request.response.close();
    });
  });

  tearDown(() => server.close(force: true));

  MlflowClient client({String path = '', String password = ''}) => MlflowClient(
    MlflowConnection(
      baseUrl: baseUrl,
      // The test CA is not a system root.
      allowUntrustedCertificate: true,
      clientCertificatePath: path,
      clientCertificatePassword: password,
    ),
  );

  Future<String> connect(MlflowClient c) async {
    try {
      final experiments = await c.searchExperiments();
      return experiments.single.name;
    } on MlflowException catch (e) {
      return e.message;
    } finally {
      c.close();
    }
  }

  test('without a client certificate the server refuses', () async {
    expect(await connect(client()), 'Authentication failed (HTTP 403)');
  });

  for (final (file, password) in [
    ('client.p12', 's3cret'),
    ('client-legacy.p12', 's3cret'),
    ('client-combined.pem', ''),
  ]) {
    test('connects with $file', () async {
      expect(await connect(client(path: '$certs/$file', password: password)), 'exp');
      expect(seenClient, contains('mlwatcher test client'));
    });
  }

  test('a wrong password is reported', () async {
    expect(
      await connect(client(path: '$certs/client.p12', password: 'nope')),
      startsWith('Client certificate: wrong password'),
    );
  });

  test('a missing file is reported', () async {
    expect(await connect(client(path: '$certs/missing.p12')), 'Client certificate: cannot read $certs/missing.p12');
  });
}
