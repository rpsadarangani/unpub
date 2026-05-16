import 'dart:io';

import 'package:unpub/unpub.dart' as unpub;
import 'package:unpub_aws/unpub_aws.dart' as aws;

/// Unified entrypoint used by the Helm chart and Dockerfile. Selects the
/// metadata store at runtime based on the `--mode` flag (or `UNPUB_MODE`).
///
///   --mode dynamo   (default) tarballs in S3, metadata in DynamoDB
///   --mode s3only   tarballs + Iceberg metadata both in S3
Future<void> main(List<String> args) async {
  final env = Platform.environment;
  final mode = _argValue(args, '--mode') ?? env['UNPUB_MODE'] ?? 'dynamo';
  final region = env['AWS_DEFAULT_REGION'] ?? env['AWS_REGION'] ?? 'ap-south-1';
  final bucket = env['UNPUB_BUCKET'] ?? 'unpub-packages';
  final port = int.parse(env['UNPUB_PORT'] ?? '4000');

  final credentials = aws.AwsCredentialChain();

  late final unpub.MetaStore meta;
  switch (mode) {
    case 's3only':
      final s3 = aws.S3Client(
        bucket: bucket,
        region: region,
        credentials: credentials,
        endpoint: env['AWS_S3_ENDPOINT'],
      );
      meta = aws.S3MetaStore(s3);
      break;
    case 'dynamo':
    default:
      final ddb = aws.DynamoClient(
        region: region,
        credentials: credentials,
        endpoint: env['AWS_DDB_ENDPOINT'],
      );
      meta = aws.DynamoMetaStore(
        client: ddb,
        table: env['UNPUB_TABLE'] ?? 'unpub-packages',
        listIndexName: env['UNPUB_LIST_INDEX'] ?? 'gsi_updated',
        downloadIndexName: env['UNPUB_DOWNLOAD_INDEX'] ?? 'gsi_download',
        statsTable: env['UNPUB_STATS_TABLE'] ?? 'unpub-stats',
      );
  }

  final app = unpub.App(
    metaStore: meta,
    packageStore: aws.S3Store(
      bucket,
      region: region,
      endpoint: env['AWS_S3_ENDPOINT'],
    ),
    overrideUploaderEmail: env['UNPUB_OVERRIDE_UPLOADER'],
    cacheUpstream: env['UNPUB_CACHE_UPSTREAM'] == 'true',
    upstream: env['UNPUB_UPSTREAM'] ?? 'https://pub.dev',
  );

  final server = await app.serve('0.0.0.0', port);
  stdout.writeln(
      'unpub mode=$mode region=$region bucket=$bucket '
      'cacheUpstream=${env["UNPUB_CACHE_UPSTREAM"] == "true"} '
      'http://${server.address.host}:${server.port}');
}

String? _argValue(List<String> args, String flag) {
  for (var i = 0; i < args.length; i++) {
    if (args[i] == flag && i + 1 < args.length) return args[i + 1];
    if (args[i].startsWith('$flag=')) {
      return args[i].substring(flag.length + 1);
    }
  }
  return null;
}
