import 'dart:async';
import 'dart:io';

import 'aws_credentials.dart';
import 'sts_credentials.dart';

/// Resolves AWS credentials lazily, refreshing on every call so callers
/// pick up rotated/temporary creds.
///
/// Order:
///   1. Explicit override (constructor-provided AwsCredentials)
///   2. IRSA / Web Identity (AWS_ROLE_ARN + AWS_WEB_IDENTITY_TOKEN_FILE)
///   3. Static env vars (AWS_ACCESS_KEY_ID + AWS_SECRET_ACCESS_KEY)
class AwsCredentialChain {
  final AwsCredentials? override;
  final StsWebIdentityProvider? webIdentity;
  final Map<String, String> environment;

  AwsCredentialChain({
    this.override,
    StsWebIdentityProvider? webIdentity,
    Map<String, String>? environment,
  })  : environment = environment ?? Platform.environment,
        webIdentity = webIdentity ??
            StsWebIdentityProvider.fromEnvironment(environment);

  Future<AwsCredentials> resolve() async {
    if (override != null) return override!;
    if (webIdentity != null) return webIdentity!.resolve();
    final keyId = environment['AWS_ACCESS_KEY_ID'];
    final secret = environment['AWS_SECRET_ACCESS_KEY'];
    final session = environment['AWS_SESSION_TOKEN'];
    if (keyId == null || secret == null) {
      throw StateError(
          'No AWS credentials found: set AWS_ROLE_ARN+AWS_WEB_IDENTITY_TOKEN_FILE '
          'or AWS_ACCESS_KEY_ID+AWS_SECRET_ACCESS_KEY, or pass credentials explicitly.');
    }
    return AwsCredentials(
      awsAccessKeyId: keyId,
      awsSecretAccessKey: secret,
      awsSessionToken: session,
    );
  }
}
