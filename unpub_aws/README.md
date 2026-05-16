# unpub_aws

AWS-backed stores for [unpub](https://github.com/pd4d10/unpub), a self-hosted private Dart Pub server.

This fork adds **two metadata stores** so you can run unpub without MongoDB:

- **`DynamoMetaStore`** — metadata in DynamoDB, tarballs in S3 (recommended for production)
- **`S3MetaStore`** — metadata AND tarballs in a single S3 bucket using an Iceberg-style snapshot layout (zero extra infra)

Both stores reuse the existing `S3Store` (a.k.a. `S3FileStore`) for tarball storage.

Credential resolution supports static keys, ECS task-role env vars, and **EKS IRSA / Web Identity** via the `AwsCredentialChain` helper.

## Available components

| Component | Purpose |
|---|---|
| `S3Store` | Tarball (`PackageStore`) on top of `S3Client` — IRSA-aware, signs each request with `X-Amz-Security-Token` |
| `S3MetaStore` | Iceberg-style `MetaStore` on S3 — immutable snapshots + CAS-swapped pointer |
| `DynamoMetaStore` | `MetaStore` on DynamoDB with atomic counters and GSI-backed listing |
| `S3Client` | Low-level SigV4 S3 client with conditional writes (`If-Match`, `If-None-Match`) |
| `DynamoClient` | Low-level SigV4 DynamoDB JSON client |
| `AwsCredentialChain` | Resolves explicit creds → IRSA (STS AssumeRoleWithWebIdentity) → static env vars |
| `StsWebIdentityProvider` | Refreshes IRSA creds at 80% of token TTL |

## Usage

### Tarballs in S3, metadata in DynamoDB

```dart
import 'dart:io';
import 'package:unpub/unpub.dart' as unpub;
import 'package:unpub_aws/unpub_aws.dart' as aws;

Future<void> main() async {
  final env = Platform.environment;
  final region = env['AWS_DEFAULT_REGION'] ?? 'ap-south-1';
  final credentials = aws.AwsCredentialChain();

  final ddb = aws.DynamoClient(
    region: region,
    credentials: credentials,
    endpoint: env['AWS_DDB_ENDPOINT'], // optional, for dynamodb-local
  );

  final app = unpub.App(
    metaStore: aws.DynamoMetaStore(client: ddb, table: 'unpub-packages'),
    packageStore: aws.S3Store(
      'unpub-packages',
      region: region,
      endpoint: env['AWS_S3_ENDPOINT'], // optional, for MinIO
    ),
  );

  final server = await app.serve('0.0.0.0', 4000);
  stdout.writeln('unpub on http://${server.address.host}:${server.port}');
}
```

DynamoDB table schema (single-table):

| Attribute | Type | Notes |
|---|---|---|
| `name` | S | partition key |
| `versions` | L of M | ordered version metadata |
| `uploaders` | SS | uploader email set |
| `private` | BOOL | |
| `createdAt`, `updatedAt` | S | ISO-8601 |
| `download` | N | atomic counter |
| `latestVersion` | S | cheap listing |
| `_all` | S | constant `"1"` — partition key for the GSI |

Recommended GSIs (Terraform creates them):

- `gsi_updated`: PK=`_all`, SK=`updatedAt` — newest-first listing
- `gsi_download`: PK=`_all`, SK=`download` — sort by downloads

### Tarballs AND metadata in S3 (no DynamoDB)

```dart
final s3 = aws.S3Client(
  bucket: 'unpub-packages',
  region: 'ap-south-1',
  credentials: aws.AwsCredentialChain(),
);

final app = unpub.App(
  metaStore: aws.S3MetaStore(s3),
  packageStore: aws.S3Store('unpub-packages', region: 'ap-south-1'),
);
```

S3 layout:

```
packages/<name>/<name>-<version>.tar.gz
meta/packages/<name>/current.json                      # pointer { snapshot, seq }
meta/packages/<name>/snap-<NNNNN>-<uuid>.json          # immutable snapshot
meta/packages/<name>/versions/<semver>.json            # immutable per-version
meta/catalog/index.json                                # global listing
meta/downloads/<yyyy-mm-dd>/<name>-<uuid>.json         # append-only events
```

Writes use S3 conditional headers (`If-None-Match: *` for immutable creates, `If-Match: <etag>` for pointer swaps), retrying on `412 Precondition Failed`.

## Credential resolution

`AwsCredentialChain` resolves credentials lazily on each request, in this order:

1. **Explicit override** — `AwsCredentialChain(override: AwsCredentials(...))`
2. **IRSA / Web Identity** — `AWS_ROLE_ARN` + `AWS_WEB_IDENTITY_TOKEN_FILE` (auto-injected by the EKS pod identity webhook). Tokens refresh at 80% of TTL.
3. **Static env vars** — `AWS_ACCESS_KEY_ID` + `AWS_SECRET_ACCESS_KEY` (+ optional `AWS_SESSION_TOKEN`)

If none of the above is available, the chain throws.

## Local development (Docker Compose)

`docker-compose.dev.yml` at the repo root spins up MinIO + DynamoDB Local + the bucket/table init steps:

```sh
docker compose -f docker-compose.dev.yml up -d minio minio-init dynamodb-local ddb-init
```

Then run a server against them (no need to build the Docker image of unpub itself):

```sh
dart compile exe unpub_aws/example/server_dynamo.dart -o /tmp/unpub-server
AWS_ACCESS_KEY_ID=minioadmin \
AWS_SECRET_ACCESS_KEY=minioadmin \
AWS_DEFAULT_REGION=ap-south-1 \
AWS_S3_ENDPOINT=http://localhost:9000 \
AWS_DDB_ENDPOINT=http://localhost:8000 \
UNPUB_BUCKET=unpub-packages \
UNPUB_TABLE=unpub-packages \
UNPUB_OVERRIDE_UPLOADER=dev@local \
/tmp/unpub-server
```

Publish a test package:

```sh
cd ~/my-pkg
dart pub publish --force --server=http://localhost:4000
```

Consume it from another project:

```yaml
# pubspec.yaml
dependencies:
  my_pkg:
    hosted:
      name: my_pkg
      url: http://localhost:4000
    version: ^0.0.1
```

> If you are on OrbStack (or another setup that auto-injects `HTTP_PROXY` into containers), the init containers explicitly clear those env vars so the AWS CLI and `mc` can reach the in-network services. See `docker-compose.dev.yml`.

## Open-source package proxying

unpub proxies pub.dev out of the box — the `upstream` parameter on `unpub.App` defaults to `https://pub.dev`. Requests for packages that aren't in your store are redirected (`302 Found`) to the upstream. This means a single unpub instance can serve as **both** your private registry and an internal mirror of pub.dev.

Override the upstream if you need a different mirror:

```dart
final app = unpub.App(
  metaStore: ...,
  packageStore: ...,
  upstream: 'https://internal-mirror.example.com',
);
```

## MongoStore parity

`DynamoMetaStore` implements the same `MetaStore` interface as the original `MongoStore`. The mapping:

| `MetaStore` method | `MongoStore` | `DynamoMetaStore` |
|---|---|---|
| `queryPackage(name)` | `findOne({name})` | `GetItem` PK=name, `ConsistentRead: true` |
| `addVersion(name, version)` | `update push versions / setOnInsert / set updatedAt`, upsert | `UpdateItem`: `SET versions = list_append`, `if_not_exists(createdAt/private/_all)`, `ADD uploaders/download` |
| `addUploader` | `update push uploaders` | `UpdateItem`: `ADD #uploaders :u SET #updatedAt = :ts`, condition `attribute_exists(name)` |
| `removeUploader` | `update pull uploaders` | `UpdateItem`: `DELETE #uploaders :u SET #updatedAt = :ts`, condition `attribute_exists(name)` |
| `increaseDownloads` | `inc download` + `inc d<yyyymmdd>` on `stats` coll | `UpdateItem`: `ADD #download :one` (atomic) |
| `queryPackages(sort/keyword/uploader/dependency)` | `find().sort().skip().limit()` + regex / `$elemMatch` | `Query` on `gsi_updated` or `gsi_download` + `FilterExpression contains(name, :kw)`; uploader and dependency filters applied post-fetch |

**Known differences:**

- Per-day download stats (`d<yyyymmdd>`) are not currently materialized in DynamoDB. If you need daily granularity, add a second table or stream-aggregate via DynamoDB Streams + Lambda.
- Keyword search uses a `contains` filter expression (post-query), not an indexed regex. Fine up to a few thousand packages; consider OpenSearch for larger catalogues.
- Dependency filtering happens in-process after fetching matching pages — same complexity class as Mongo when nested array indexes aren't hit.

## Verified locally

Smoke-tested against the Compose stack:

- Publish a private package via `dart pub publish` → tarball lands in MinIO at `packages/<name>/<name>-<v>.tar.gz`, full metadata in DynamoDB
- `GET /api/packages/<name>` returns the version graph including `archive_url`
- `dart pub get` against `hosted: url: http://localhost:4000` installs the package
- Atomic `download` counter increments on every pub-client tarball fetch (verified `0 → 1 → 6`)
- Unknown packages (e.g. `path`) redirect with `302` to `https://pub.dev`
