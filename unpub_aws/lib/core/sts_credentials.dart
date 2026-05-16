import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

import 'aws_credentials.dart';

/// Credentials obtained from STS AssumeRoleWithWebIdentity (IRSA on EKS).
///
/// Refreshes automatically when the cached creds approach expiry.
class StsWebIdentityProvider {
  final String roleArn;
  final String tokenFile;
  final String? region;
  final String sessionName;
  final Duration refreshSkew;
  final http.Client _client;

  AwsCredentials? _cached;
  DateTime? _expiresAt;
  Future<AwsCredentials>? _inflight;

  StsWebIdentityProvider({
    required this.roleArn,
    required this.tokenFile,
    this.region,
    this.sessionName = 'unpub',
    this.refreshSkew = const Duration(minutes: 5),
    http.Client? client,
  }) : _client = client ?? http.Client();

  /// Build provider from EKS pod environment variables.
  ///
  /// Returns null if the pod does not appear to have IRSA injected.
  static StsWebIdentityProvider? fromEnvironment(
      [Map<String, String>? environment]) {
    final env = environment ?? Platform.environment;
    final roleArn = env['AWS_ROLE_ARN'];
    final tokenFile = env['AWS_WEB_IDENTITY_TOKEN_FILE'];
    if (roleArn == null || tokenFile == null) return null;
    return StsWebIdentityProvider(
      roleArn: roleArn,
      tokenFile: tokenFile,
      region: env['AWS_REGION'] ?? env['AWS_DEFAULT_REGION'],
      sessionName: env['AWS_ROLE_SESSION_NAME'] ?? 'unpub',
    );
  }

  Future<AwsCredentials> resolve() async {
    if (_cached != null &&
        _expiresAt != null &&
        DateTime.now().toUtc().isBefore(_expiresAt!.subtract(refreshSkew))) {
      return _cached!;
    }
    return _inflight ??= _refresh().whenComplete(() => _inflight = null);
  }

  Future<AwsCredentials> _refresh() async {
    final token = await File(tokenFile).readAsString();
    final host = region == null
        ? 'sts.amazonaws.com'
        : 'sts.$region.amazonaws.com';

    final uri = Uri.https(host, '/', {
      'Action': 'AssumeRoleWithWebIdentity',
      'Version': '2011-06-15',
      'RoleArn': roleArn,
      'RoleSessionName': sessionName,
      'WebIdentityToken': token.trim(),
      'DurationSeconds': '3600',
    });

    final res = await _client.get(uri);
    if (res.statusCode != 200) {
      throw StateError(
          'STS AssumeRoleWithWebIdentity failed: ${res.statusCode} ${res.body}');
    }

    final doc = XmlDocument.parse(res.body);
    final creds = doc.findAllElements('Credentials').first;
    final accessKeyId = creds.getElement('AccessKeyId')!.innerText;
    final secret = creds.getElement('SecretAccessKey')!.innerText;
    final session = creds.getElement('SessionToken')!.innerText;
    final expIso = creds.getElement('Expiration')!.innerText;

    final out = AwsCredentials(
      awsAccessKeyId: accessKeyId,
      awsSecretAccessKey: secret,
      awsSessionToken: session,
    );
    _cached = out;
    _expiresAt = DateTime.parse(expIso).toUtc();
    return out;
  }
}
