import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:minio/minio.dart';
import 'package:unpub/unpub.dart';

import '../core/aws_credentials.dart';

/// Use an AWS S3 bucket (or S3-compatible endpoint like MinIO) as a package store.
class S3Store extends PackageStore {
  String Function(String name, String version)? getObjectPath;

  String bucketName;
  String? region;
  String? endpoint;
  AwsCredentials? credentials;
  Minio? minio;
  Map<String, String>? environment;

  S3Store(
    this.bucketName, {
    this.region,
    this.getObjectPath,
    this.endpoint,
    this.credentials,
    this.minio,
    this.environment,
  }) {
    final env = environment ?? Platform.environment;
    credentials ??= AwsCredentials(environment: env);

    final endpointUrl = endpoint ?? env['AWS_S3_ENDPOINT'] ?? 'https://s3.amazonaws.com';
    final parsed = Uri.parse(endpointUrl.startsWith('http')
        ? endpointUrl
        : 'https://$endpointUrl');

    minio ??= Minio(
      endPoint: parsed.host,
      port: parsed.hasPort ? parsed.port : null,
      useSSL: parsed.scheme == 'https',
      region: region ?? env['AWS_DEFAULT_REGION'] ?? env['AWS_REGION'],
      accessKey: credentials!.awsAccessKeyId ?? '',
      secretKey: credentials!.awsSecretAccessKey ?? '',
      sessionToken: credentials!.awsSessionToken,
    );

    if (region == null &&
        (env['AWS_DEFAULT_REGION']?.isEmpty ?? true) &&
        (env['AWS_REGION']?.isEmpty ?? true)) {
      throw ArgumentError('Could not determine a default region for aws.');
    }
  }

  String _getObjectKey(String name, String version) =>
      getObjectPath?.call(name, version) ?? '$name/$name-$version.tar.gz';

  @override
  Future<void> upload(String name, String version, List<int> content) async {
    await minio!.putObject(
      bucketName,
      _getObjectKey(name, version),
      Stream.value(Uint8List.fromList(content)),
    );
  }

  @override
  Stream<List<int>> download(String name, String version) async* {
    final stream =
        await minio!.getObject(bucketName, _getObjectKey(name, version));
    yield* stream;
  }

  @override
  Future<bool> exists(String name, String version) async {
    try {
      await minio!.statObject(bucketName, _getObjectKey(name, version));
      return true;
    } catch (_) {
      return false;
    }
  }
}
