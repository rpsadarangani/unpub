import 'dart:io';

import 'package:unpub/unpub.dart' as unpub;
import 'package:unpub_aws/unpub_aws.dart' as aws;

/// Reference server: tarballs AND metadata in S3 (Iceberg-style layout).
///
/// Required env vars:
///   AWS_DEFAULT_REGION   ap-south-1
///   UNPUB_BUCKET         packages-bucket
/// Optional (local/dev):
///   AWS_S3_ENDPOINT      http://localhost:9000
///   AWS_ACCESS_KEY_ID    minioadmin
///   AWS_SECRET_ACCESS_KEY minioadmin
Future<void> main(List<String> args) async {
  final env = Platform.environment;
  final region = env['AWS_DEFAULT_REGION'] ?? env['AWS_REGION'] ?? 'ap-south-1';
  final bucket = env['UNPUB_BUCKET'] ?? 'unpub-packages';

  final credentials = aws.AwsCredentialChain();

  final s3 = aws.S3Client(
    bucket: bucket,
    region: region,
    credentials: credentials,
    endpoint: env['AWS_S3_ENDPOINT'],
  );

  final app = unpub.App(
    metaStore: aws.S3MetaStore(s3),
    packageStore: aws.S3Store(
      bucket,
      region: region,
      endpoint: env['AWS_S3_ENDPOINT'],
    ),
    overrideUploaderEmail: env['UNPUB_OVERRIDE_UPLOADER'],
    cacheUpstream: env['UNPUB_CACHE_UPSTREAM'] == 'true',
    upstream: env['UNPUB_UPSTREAM'] ?? 'https://pub.dev',
  );

  final port = int.parse(env['UNPUB_PORT'] ?? '4000');
  final server = await app.serve('0.0.0.0', port);
  stdout.writeln('unpub (s3-only) on http://${server.address.host}:${server.port}');
}
