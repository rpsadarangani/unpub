# unpub

[![Release](https://img.shields.io/github/v/release/rpsadarangani/unpub?display_name=tag)](https://github.com/rpsadarangani/unpub/releases)
[![CI](https://github.com/rpsadarangani/unpub/actions/workflows/test.yml/badge.svg)](https://github.com/rpsadarangani/unpub/actions/workflows/test.yml)
[![License](https://img.shields.io/github/license/rpsadarangani/unpub)](./LICENSE)

A self-hosted private **Dart / Flutter pub server** with **AWS-native storage**, **Athens-style pull-through caching** of [pub.dev](https://pub.dev), and **Prometheus metrics** — all behind a single small Dart binary.

> Fork of [pd4d10/unpub](https://github.com/pd4d10/unpub) (originally by [bytedance/unpub](https://github.com/bytedance/unpub)). Adds DynamoDB and S3-only metadata backends, IRSA credentials, upstream caching, Prometheus metrics, and a Helm chart + GHCR release pipeline.

```
   client (dart pub get / publish)
            │
            ▼
   ┌──────────────────┐         miss          ┌────────────┐
   │       unpub      │ ────────────────────▶ │   pub.dev  │
   │  (Dart, ~8 MB    │ ◀── tarball + meta ── └────────────┘
   │   AOT binary)    │
   └────────┬─────────┘
            │
            ├──── tarballs ──▶  S3
            └──── metadata ──▶  DynamoDB   (or S3-only, Iceberg-style)
```

## Why

- **Drop MongoDB.** Two AWS-native metadata backends — DynamoDB (recommended) or pure S3 (Iceberg-style snapshots + CAS-swapped pointer). No extra database to operate.
- **Cache pub.dev locally.** Every cache miss fetches from `pub.dev`, stores in your bucket, and is served from your own S3 forever after. Athens for Dart.
- **IRSA out of the box.** Credentials resolved from EKS pod identity (Web Identity → STS `AssumeRoleWithWebIdentity`), with automatic refresh and static-keys fallback for ECS / dev.
- **Prometheus-native observability.** `/metrics` exposes request histograms, cache hit/miss counters, fetch latency, in-flight gauges, and per-package upload/download counters — no extra deps in the binary.
- **One small container.** Multi-arch AOT Dart binary, < 20 MB image, no JVM, no Node.

## Using a deployed instance

Once unpub is running, point any Dart / Flutter client at it with one env var:

```sh
export PUB_HOSTED_URL=https://unpub.example.internal

# Consume packages (works for both pub.dev mirrors and your private uploads)
dart pub get          # or:  flutter pub get

# Publish a private package
dart pub publish --server=$PUB_HOSTED_URL
# or, in pubspec.yaml:
#   publish_to: https://unpub.example.internal
```

In CI:

```yaml
# .github/workflows/*.yml
env:
  PUB_HOSTED_URL: https://unpub.example.internal
```

```dockerfile
# Dockerfile
ARG PUB_HOSTED_URL=https://unpub.example.internal
ENV PUB_HOSTED_URL=$PUB_HOSTED_URL
```

The first time anyone fetches a given `<pkg>@<version>` the proxy pulls it from `pub.dev` and stores it in S3. Subsequent fetches stay entirely inside the VPC.

## Quickstart

> Want the full production runbook (S3 + DynamoDB + IRSA + Helm + DNS + smoke tests)? See [docs/deployment.md](./docs/deployment.md).

### Run with Docker (local stack)

```sh
git clone https://github.com/rpsadarangani/unpub
cd unpub
docker compose -f docker-compose.dev.yml up -d minio minio-init dynamodb-local ddb-init

docker run --rm --network unpub_default \
  -e AWS_ACCESS_KEY_ID=minioadmin \
  -e AWS_SECRET_ACCESS_KEY=minioadmin \
  -e AWS_DEFAULT_REGION=ap-south-1 \
  -e AWS_S3_ENDPOINT=http://minio:9000 \
  -e AWS_DDB_ENDPOINT=http://dynamodb-local:8000 \
  -e UNPUB_BUCKET=unpub-packages \
  -e UNPUB_TABLE=unpub-packages \
  -e UNPUB_CACHE_UPSTREAM=true \
  -p 4000:4000 \
  ghcr.io/rpsadarangani/unpub:latest
```

Then point your client at it:

```sh
export PUB_HOSTED_URL=http://localhost:4000
dart pub get
```

### Install on Kubernetes (Helm + OCI)

```sh
helm install unpub oci://ghcr.io/rpsadarangani/charts/unpub --version 0.1.0 \
  -n devtools --create-namespace \
  --set aws.region=ap-south-1 \
  --set aws.bucket=my-unpub-packages \
  --set aws.ddbTable=unpub-packages \
  --set 'serviceAccount.annotations.eks\.amazonaws\.com/role-arn=arn:aws:iam::ACCT:role/unpub'
```

Chart docs and full value reference live in [`charts/unpub/README.md`](./charts/unpub/README.md).

## Storage modes

| Mode | Tarballs | Metadata | Notes |
|---|---|---|---|
| `dynamo` *(default)* | S3 | DynamoDB | Single-digit-ms reads, atomic counters, GSI listing, optional daily-stats table. |
| `s3only` | S3 | S3 (Iceberg-style) | Zero non-S3 infra. Immutable `snap-N-uuid.json` snapshots + CAS-swapped `current.json` pointer + per-version files + global catalog. |

Both modes share the same tarball key layout, so you can switch between them by changing one CLI flag (`--mode dynamo|s3only`) — your packages stay where they are.

## Upstream caching

```dart
final app = unpub.App(
  metaStore: ...,
  packageStore: ...,
  cacheUpstream: true,                  // ◀── enable Athens-style caching
  upstream: 'https://pub.dev',          // (default)
);
```

- On miss: fetch metadata from `pub.dev`, return synthetic response to the client immediately, persist each version in the background with bounded concurrency.
- On miss: fetch tarball from `https://pub.dev/api/archives/<name>-<version>.tar.gz`, `PUT` to S3, stream to client.
- Concurrent first-fetches for the same package or `name@version` are deduped through in-memory inflight maps so cold-cache spikes only hit upstream once.
- Subsequent requests are served entirely from your own store.

Bench measured on EKS (IRSA, behind an Istio NLB) against a live S3 + DynamoDB cache. Cold = miss → `pub.dev` → S3 upload → serve; warm = single S3 GET.

| Package | Size | Cold | Warm |
|---|---:|---:|---:|
| `path@1.9.1` | 44 KiB | 0.53 s | 0.41 s |
| `firebase_core@4.9.0` | 259 KiB | 0.57 s | 0.48 s |
| `flutter_local_notifications@21.0.0` | 710 KiB | 0.73 s | ~1 s |
| `cloud_firestore@6.4.1` | 848 KiB | 1.45 s | 0.58 s |
| `googleapis@16.0.0` | **9.4 MiB** | 3.18 s | **1.92 s** |

## Observability

`GET /metrics` returns Prometheus text exposition (`Content-Type: text/plain; version=0.0.4`). Key series:

```
unpub_http_requests_total{route,method,status}            counter
unpub_http_request_duration_seconds_bucket{route,method}  histogram
unpub_upstream_cache_hits_total{kind=metadata|tarball}    counter
unpub_upstream_cache_misses_total{kind=...}               counter
unpub_upstream_fetch_duration_seconds_bucket{kind,le}     histogram
unpub_upstream_dedup_hits_total{kind=...}                 counter
unpub_inflight_upstream_metadata                          gauge
unpub_inflight_upstream_tarballs                          gauge
unpub_uploads_total{package}                              counter
unpub_downloads_total{package}                            counter
```

Route labels are templates (`/api/packages/<name>` rather than concrete names), so the series count stays bounded as the catalogue grows. The Helm chart exposes a `vmServiceScrape.enabled` toggle (VictoriaMetrics Operator) — pod-annotation scraping works for vanilla Prometheus.

## Authentication

`AwsCredentialChain` resolves lazily on every request:

1. Explicit override (`AwsCredentialChain(override: AwsCredentials(...))`).
2. **IRSA / Web Identity** — `AWS_ROLE_ARN` + `AWS_WEB_IDENTITY_TOKEN_FILE` (auto-injected by the EKS pod-identity webhook). STS `AssumeRoleWithWebIdentity`, refresh at 80% of the token TTL.
3. Static env vars — `AWS_ACCESS_KEY_ID` + `AWS_SECRET_ACCESS_KEY` (+ optional `AWS_SESSION_TOKEN`).

Both `S3Store` and `DynamoMetaStore` re-resolve through the chain on every operation, so STS-issued session tokens flow into the SigV4 `X-Amz-Security-Token` header on each S3 / DynamoDB call. **No periodic refresh hack is needed**, and the binary works out of the box on EKS with IRSA.

The Helm chart supports both paths: IRSA via `serviceAccount.annotations`, static keys via `externalSecret.enabled` (works with both v1beta1 and v1 ExternalSecrets).

## Repository layout

| Path | What |
|---|---|
| [`unpub/`](./unpub) | Server core (router, handlers, models, metrics, upstream caching). |
| [`unpub_aws/`](./unpub_aws) | AWS backends: `S3Store`, `S3MetaStore` (Iceberg), `DynamoMetaStore`, `S3Client`, `DynamoClient`, SigV4 signer, IRSA chain. |
| [`unpub_auth/`](./unpub_auth), [`unpub_web/`](./unpub_web) | Auth helpers + web UI (inherited from upstream). |
| [`charts/unpub/`](./charts/unpub) | Helm chart published as `oci://ghcr.io/rpsadarangani/charts/unpub`. |
| [`Dockerfile`](./Dockerfile), [`docker-compose.dev.yml`](./docker-compose.dev.yml) | Container build + local dev stack (MinIO + DynamoDB Local). |
| [`.github/workflows/`](./.github/workflows) | CI: `dart analyze` + `helm lint` on every PR; multi-arch Docker + OCI Helm publish on tag `v*`. |

## Releases

Every Git tag matching `v*` rebuilds and pushes:

- `ghcr.io/rpsadarangani/unpub:<tag>` (multi-arch `linux/amd64` + `linux/arm64`)
- `oci://ghcr.io/rpsadarangani/charts/unpub:<tag without v>` (chart with `image.tag` pinned)

See [`CHANGELOG`](./CHANGELOG.md) or the [releases page](https://github.com/rpsadarangani/unpub/releases).

## Contributing

Bug reports, feature requests, and PRs are very welcome. Please read [`CONTRIBUTING.md`](./CONTRIBUTING.md) for the development setup, and report security issues per [`SECURITY.md`](./SECURITY.md).

## Credits

- [@pd4d10](https://github.com/pd4d10) and [bytedance/unpub](https://github.com/bytedance/unpub) for the original server.
- [@Clean-Cole](https://github.com/Clean-Cole) for `unpub_aws/S3Store`.
- The Apache Iceberg snapshot/pointer pattern that inspired `S3MetaStore`.

## License

[MIT](./LICENSE) — same as upstream.
