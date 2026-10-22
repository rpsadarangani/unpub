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

  // S3Store now uses the in-house S3Client + AwsCredentialChain, so it
  // signs every request with fresh STS web-identity credentials and
  // includes X-Amz-Security-Token. No periodic refresh needed.
  // Behind TLS-terminating ingress (Istio gateway, ALB, nginx, …) the pod
  // sees plain HTTP. `dart pub publish` reads the upload URL the server
  // returns from `/api/packages/versions/new` and POSTs to it directly, so
  // that URL must be the public HTTPS origin — otherwise the client tries
  // `http://<host>:0/...` and times out. UNPUB_PUBLIC_URL is the override.
  final publicUrl = env['UNPUB_PUBLIC_URL'];
  final app = unpub.App(
    metaStore: meta,
    packageStore: aws.S3Store(
      bucket,
      region: region,
      endpoint: env['AWS_S3_ENDPOINT'],
      credentials: credentials,
    ),
    overrideUploaderEmail: env['UNPUB_OVERRIDE_UPLOADER'],
    cacheUpstream: env['UNPUB_CACHE_UPSTREAM'] == 'true',
    upstream: env['UNPUB_UPSTREAM'] ?? 'https://pub.dev',
    upstreamToken: env['UNPUB_UPSTREAM_TOKEN'],
    upstreamUsername: env['UNPUB_UPSTREAM_USERNAME'],
    upstreamPassword: env['UNPUB_UPSTREAM_PASSWORD'],
    upstreamMetadataTtl: Duration(
        seconds: int.parse(env['UNPUB_UPSTREAM_METADATA_TTL'] ?? '600')),
    extraUpstreams: _extraUpstreams(env),
    proxy_origin:
        publicUrl != null && publicUrl.isNotEmpty ? Uri.parse(publicUrl) : null,
  );

  final server = await app.serve('0.0.0.0', port);
  stdout.writeln('unpub mode=$mode region=$region bucket=$bucket '
      'upstreams=${[
    ...app.extraUpstreams.map((u) => u.toString()),
    app.upstream
  ]} '
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

/// Private upstreams from `UNPUB_UPSTREAM_<n>_URL` (+ `_TOKEN`, or
/// `_USERNAME` / `_PASSWORD`), n = 1, 2, … until the first gap. They are
/// consulted, in order, before `UNPUB_UPSTREAM`.
List<unpub.Upstream> _extraUpstreams(Map<String, String> env) {
  final upstreams = <unpub.Upstream>[];
  for (var n = 1;; n++) {
    final url = env['UNPUB_UPSTREAM_${n}_URL'];
    if (url == null || url.isEmpty) break;
    upstreams.add(unpub.Upstream(
      url,
      token: env['UNPUB_UPSTREAM_${n}_TOKEN'],
      username: env['UNPUB_UPSTREAM_${n}_USERNAME'],
      password: env['UNPUB_UPSTREAM_${n}_PASSWORD'],
    ));
  }
  return upstreams;
}
