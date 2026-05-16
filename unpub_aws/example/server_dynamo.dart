import 'dart:io';

import 'package:unpub/unpub.dart' as unpub;
import 'package:unpub_aws/unpub_aws.dart' as aws;

/// Reference server: tarballs in S3, metadata in DynamoDB.
///
/// Required env vars:
///   AWS_DEFAULT_REGION   ap-south-1
///   UNPUB_BUCKET         packages-bucket
///   UNPUB_TABLE          unpub-packages
/// Optional (local/dev):
///   AWS_S3_ENDPOINT      http://localhost:9000
///   AWS_DDB_ENDPOINT     http://localhost:8000
///   AWS_ACCESS_KEY_ID    minioadmin
///   AWS_SECRET_ACCESS_KEY minioadmin
/// IRSA env vars (production on EKS):
///   AWS_ROLE_ARN, AWS_WEB_IDENTITY_TOKEN_FILE
Future<void> main(List<String> args) async {
  final env = Platform.environment;
  final region = env['AWS_DEFAULT_REGION'] ?? env['AWS_REGION'] ?? 'ap-south-1';
  final bucket = env['UNPUB_BUCKET'] ?? 'unpub-packages';
  final table = env['UNPUB_TABLE'] ?? 'unpub-packages';

  final credentials = aws.AwsCredentialChain();

  final ddb = aws.DynamoClient(
    region: region,
    credentials: credentials,
    endpoint: env['AWS_DDB_ENDPOINT'],
  );

  final app = unpub.App(
    metaStore: aws.DynamoMetaStore(client: ddb, table: table),
    packageStore: aws.S3Store(
      bucket,
      region: region,
      endpoint: env['AWS_S3_ENDPOINT'],
    ),
    overrideUploaderEmail: env['UNPUB_OVERRIDE_UPLOADER'],
  );

  final port = int.parse(env['UNPUB_PORT'] ?? '4000');
  final server = await app.serve('0.0.0.0', port);
  stdout.writeln('unpub (dynamo) on http://${server.address.host}:${server.port}');
}
