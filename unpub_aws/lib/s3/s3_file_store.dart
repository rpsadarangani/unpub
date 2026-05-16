import 'dart:async';
import 'dart:io';

import 'package:unpub/unpub.dart';

import '../core/credential_chain.dart';
import 's3_client.dart';

/// Tarball (`PackageStore`) backed by S3.
///
/// Uses the in-house [S3Client] (raw HTTPS + SigV4) so the store works
/// out of the box with IRSA / STS web-identity / refreshing session
/// tokens — the upstream minio Dart client does not include
/// `X-Amz-Security-Token` on standard PUT/GET headers, which makes it
/// useless for IRSA-issued temporary credentials.
class S3Store extends PackageStore {
  /// Optional override for tarball key layout. Default:
  /// `<name>/<name>-<version>.tar.gz`.
  String Function(String name, String version)? getObjectPath;

  final String bucketName;
  final String region;
  final String? endpoint;
  final AwsCredentialChain credentials;
  S3Client client;

  S3Store(
    this.bucketName, {
    String? region,
    this.getObjectPath,
    this.endpoint,
    AwsCredentialChain? credentials,
    Map<String, String>? environment,
    S3Client? client,
  })  : region = region ??
            (environment ?? Platform.environment)['AWS_DEFAULT_REGION'] ??
            (environment ?? Platform.environment)['AWS_REGION'] ??
            (throw ArgumentError(
                'S3Store: AWS_DEFAULT_REGION (or AWS_REGION) is required.')),
        credentials = credentials ?? AwsCredentialChain(environment: environment),
        client = client ??
            S3Client(
              bucket: bucketName,
              region: region ??
                  (environment ?? Platform.environment)['AWS_DEFAULT_REGION'] ??
                  (environment ?? Platform.environment)['AWS_REGION']!,
              credentials:
                  credentials ?? AwsCredentialChain(environment: environment),
              endpoint: endpoint,
            );

  String _key(String name, String version) =>
      getObjectPath?.call(name, version) ?? '$name/$name-$version.tar.gz';

  @override
  Future<void> upload(String name, String version, List<int> content) async {
    await client.putObject(
      _key(name, version),
      content,
      contentType: 'application/gzip',
    );
  }

  @override
  Stream<List<int>> download(String name, String version) async* {
    final res = await client.getObject(_key(name, version));
    if (!res.exists || res.body == null) {
      throw 'S3Store: object ${_key(name, version)} not found';
    }
    yield res.body!;
  }

  @override
  Future<bool> exists(String name, String version) =>
      client.headObject(_key(name, version));
}
