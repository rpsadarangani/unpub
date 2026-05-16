import 'dart:io';

/// Static AWS credential holder. Resolves from constructor args or env vars.
///
/// For dynamic resolution (IRSA, refreshing creds) see [AwsCredentialChain].
class AwsCredentials {
  String? awsAccessKeyId;
  String? awsSecretAccessKey;
  String? awsSessionToken;
  Map<String, String>? environment;

  AwsCredentials({
    this.awsAccessKeyId,
    this.awsSecretAccessKey,
    this.awsSessionToken,
    this.environment,
  }) {
    final env = environment ?? Platform.environment;
    environment ??= Platform.environment;
    awsAccessKeyId ??= env['AWS_ACCESS_KEY_ID'];
    awsSecretAccessKey ??= env['AWS_SECRET_ACCESS_KEY'];
    awsSessionToken ??= env['AWS_SESSION_TOKEN'];

    if (awsAccessKeyId == null || awsSecretAccessKey == null) {
      throw ArgumentError(
          'AwsCredentials: provide AWS_ACCESS_KEY_ID + AWS_SECRET_ACCESS_KEY '
          '(env vars or constructor). For IRSA, use AwsCredentialChain.');
    }
  }
}
