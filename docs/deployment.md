# Deployment guide

End-to-end setup for running unpub on AWS:

1. [Pick a metadata mode](#1-pick-a-metadata-mode)
2. [Provision AWS resources](#2-provision-aws-resources) — S3, DynamoDB, IAM/IRSA
3. [Install with Helm](#3-install-with-helm)
4. [Wire DNS + ingress](#4-wire-dns--ingress)
5. [Smoke test](#5-smoke-test)
6. [Local dev with Docker Compose](#6-local-dev-with-docker-compose)
7. [Operations](#7-operations)

Glossary up front:

| Term | What |
|---|---|
| `dynamo` mode | Tarballs in S3, metadata in DynamoDB (recommended for prod). |
| `s3only` mode | Tarballs **and** metadata in one S3 bucket using an Iceberg-style snapshot layout. Zero non-S3 infra. |
| Cache-on-miss | When `cacheUpstream: true`, unknown packages are fetched from `pub.dev` once, stored in your bucket, then served locally from then on. |

## 1. Pick a metadata mode

| Mode | Tarballs | Metadata | When to pick |
|---|---|---|---|
| `dynamo` *(default)* | S3 | DynamoDB | Production. Single-digit-ms metadata reads, atomic download counters, indexed listing. Two cheap PAY_PER_REQUEST tables. |
| `s3only` | S3 | S3 (Iceberg-style) | Cheapest, zero non-S3 infra. Listing/sort is O(N) reads — fine up to a few thousand packages. |

Both modes share the same S3 tarball layout (`packages/<name>/<name>-<v>.tar.gz`), so you can switch by changing one CLI flag (`--mode dynamo|s3only`) without moving anything.

## 2. Provision AWS resources

### 2.1 S3 bucket

| Setting | Value |
|---|---|
| Name | `<env>-unpub-packages` (your choice; private) |
| Block public access | **All four toggles ON** — unpub itself only ever pre-signs / proxies content. |
| Versioning | Enabled (so the Iceberg snapshot scheme works in `s3only` mode, and so accidental deletes are recoverable in `dynamo` mode). |
| Encryption | SSE-KMS with a CMK you own (`alias/<acct-id>/s3` or a dedicated key). Plain SSE-S3 works too. |
| Lifecycle | Optional — expire incomplete multipart uploads after 7d. |

Bare-Terraform variant:

```hcl
module "s3_unpub_packages" {
  source = "git::ssh://git@github.com/<your-org>/<tf-modules>//aws/modules/s3?ref=<commit>"
  bucket = {
    name               = "ne-non-prod-unpub-packages"
    logging_enabled    = false
    versioning_enabled = true
  }
  aws_s3_kms_key_primary_alias = "alias/<account-id>/s3"
}
```

Or with the raw provider:

```hcl
resource "aws_s3_bucket" "unpub" {
  bucket = "unpub-packages"
}

resource "aws_s3_bucket_versioning" "unpub" {
  bucket = aws_s3_bucket.unpub.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_public_access_block" "unpub" {
  bucket                  = aws_s3_bucket.unpub.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "unpub" {
  bucket = aws_s3_bucket.unpub.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_alias.s3.target_key_arn
    }
    bucket_key_enabled = true
  }
}
```

### 2.2 DynamoDB tables (`dynamo` mode only)

Two tables. Both PAY_PER_REQUEST, PITR on, KMS-encrypted, deletion-protected.

**`unpub-packages`** — the metadata store.

| Attribute | Type | Role |
|---|---|---|
| `name` | S | partition key |
| `_all` | S | constant `"1"`, partition key for GSIs (low-cardinality global listing) |
| `updatedAt` | S | range key for `gsi_updated` |
| `download` | N | range key for `gsi_download` |
| (plus `versions`, `uploaders`, `private`, `createdAt`, `latestVersion`, `download`, …) | | written by the server, not part of the key/GSI schema |

GSIs:

- `gsi_updated`: `_all` (HASH) + `updatedAt` (RANGE) — newest-first listing.
- `gsi_download`: `_all` (HASH) + `download` (RANGE) — sort by downloads.

**`unpub-stats`** — daily / per-version counters (MongoStore parity).

| Attribute | Type | Role |
|---|---|---|
| `name` | S | partition key |
| `date` | S | range key (ISO `yyyy-mm-dd`) |

Each row carries `total` (number) plus one `v_<sem_ver>` attribute per version, all incremented atomically on download.

Terraform:

```hcl
locals { kms_key_arn = aws_kms_alias.s3.target_key_arn }

resource "aws_dynamodb_table" "unpub_packages" {
  name         = "unpub-packages"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "name"

  deletion_protection_enabled = true

  attribute { name = "name"      type = "S" }
  attribute { name = "_all"      type = "S" }
  attribute { name = "updatedAt" type = "S" }
  attribute { name = "download"  type = "N" }

  global_secondary_index {
    name            = "gsi_updated"
    hash_key        = "_all"
    range_key       = "updatedAt"
    projection_type = "ALL"
  }
  global_secondary_index {
    name            = "gsi_download"
    hash_key        = "_all"
    range_key       = "download"
    projection_type = "ALL"
  }

  point_in_time_recovery { enabled = true }
  server_side_encryption { enabled = true  kms_key_arn = local.kms_key_arn }
}

resource "aws_dynamodb_table" "unpub_stats" {
  name         = "unpub-stats"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "name"
  range_key    = "date"

  deletion_protection_enabled = true

  attribute { name = "name" type = "S" }
  attribute { name = "date" type = "S" }

  point_in_time_recovery { enabled = true }
  server_side_encryption { enabled = true  kms_key_arn = local.kms_key_arn }
}
```

The DDB table init step in `docker-compose.dev.yml` mirrors the same schema if you prefer copying from there.

### 2.3 IAM role for IRSA

unpub's `AwsCredentialChain` looks up `AWS_ROLE_ARN` + `AWS_WEB_IDENTITY_TOKEN_FILE` (auto-injected by the EKS pod-identity webhook) and calls STS `AssumeRoleWithWebIdentity`, refreshing at 80% of the token's TTL.

Required permissions:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "UnpubS3",
      "Effect": "Allow",
      "Action": [
        "s3:GetObject", "s3:PutObject", "s3:DeleteObject",
        "s3:ListBucket", "s3:GetBucketLocation"
      ],
      "Resource": [
        "arn:aws:s3:::unpub-packages",
        "arn:aws:s3:::unpub-packages/*"
      ]
    },
    {
      "Sid": "UnpubDynamoDB",
      "Effect": "Allow",
      "Action": [
        "dynamodb:GetItem", "dynamodb:BatchGetItem",
        "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:DeleteItem",
        "dynamodb:Query", "dynamodb:Scan", "dynamodb:DescribeTable"
      ],
      "Resource": [
        "arn:aws:dynamodb:<region>:<acct>:table/unpub-packages",
        "arn:aws:dynamodb:<region>:<acct>:table/unpub-packages/index/*",
        "arn:aws:dynamodb:<region>:<acct>:table/unpub-stats",
        "arn:aws:dynamodb:<region>:<acct>:table/unpub-stats/index/*"
      ]
    },
    {
      "Sid": "UnpubKMS",
      "Effect": "Allow",
      "Action": ["kms:GenerateDataKey", "kms:Decrypt"],
      "Resource": "arn:aws:kms:<region>:<acct>:key/<key-id>"
    }
  ]
}
```

Trust policy (the SA that will assume this role lives in `<namespace>/unpub`):

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "Federated": "arn:aws:iam::<acct>:oidc-provider/oidc.eks.<region>.amazonaws.com/id/<cluster-id>"
    },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "oidc.eks.<region>.amazonaws.com/id/<cluster-id>:aud": "sts.amazonaws.com",
        "oidc.eks.<region>.amazonaws.com/id/<cluster-id>:sub": "system:serviceaccount:<namespace>:unpub"
      }
    }
  }]
}
```

For `s3only` mode, drop the entire DynamoDB statement.

> **Skipping IRSA?** Provide `AWS_ACCESS_KEY_ID` + `AWS_SECRET_ACCESS_KEY` (+ optional `AWS_SESSION_TOKEN`) via the chart's `externalSecret.*` values. unpub re-resolves credentials on every request, so rotated keys flow in without restart.

## 3. Install with Helm

```sh
helm install unpub oci://ghcr.io/rpsadarangani/charts/unpub --version 0.2.2 \
  -n devtools --create-namespace \
  --set aws.region=<region> \
  --set aws.bucket=unpub-packages \
  --set aws.ddbTable=unpub-packages \
  --set aws.ddbStatsTable=unpub-stats \
  --set 'serviceAccount.annotations.eks\.amazonaws\.com/role-arn=arn:aws:iam::<acct>:role/unpub'
```

Or commit a values file (see [`charts/unpub/values.yaml`](../charts/unpub/values.yaml) for the full reference) and use ArgoCD / Flux.

Minimal `values.yaml`:

```yaml
image:
  repository: ghcr.io/rpsadarangani/unpub
  tag: "v0.2.2"

fullnameOverride: unpub
mode: dynamo
cacheUpstream: true

aws:
  region: ap-south-1
  bucket: unpub-packages
  ddbTable: unpub-packages
  ddbStatsTable: unpub-stats

serviceAccount:
  create: true
  name: unpub
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::000000000000:role/unpub

resources:
  requests:
    cpu: 500m
    memory: 1Gi
  limits:
    memory: 2Gi

hpa:
  enabled: true
  apiVersionOverride: autoscaling/v2
  minReplicas: 2
  maxReplicas: 5
  targetCPUUtilizationPercentage: 75
  targetMemoryUtilizationPercentage: 75

vmServiceScrape:
  enabled: true   # set to false (and use podAnnotations) on plain Prometheus
```

`s3only` mode? Set `mode: s3only` and remove `aws.ddbTable` / `aws.ddbStatsTable` from values. The IAM policy block for DynamoDB also goes away.

## 4. Wire DNS + ingress

Two paths; pick one in `values.yaml`:

```yaml
ingress:
  enabled: true
  className: nginx
  host: unpub.example.internal
  tls:
    - hosts: [unpub.example.internal]
      secretName: unpub-tls
```

```yaml
istio:
  enabled: true
  gateway: istio-system/internal-gateway
  host: unpub.example.internal
```

Then add a Route53 / Cloud DNS record pointing the host at your ingress (private NLB or ALB). HTTPS only — `dart pub` refuses to talk to plain HTTP except `localhost`.

If your environment already has a wildcard CNAME (`*.internal` → ingress NLB), no per-service DNS record is needed.

## 5. Smoke test

```sh
# 1. metrics endpoint up
curl -sf https://unpub.example.internal/metrics | head

# 2. metadata for a pub.dev package — first hit warms the cache
curl -sf https://unpub.example.internal/api/packages/path | head -c 200

# 3. tarball — should be 200 and 40-50 KB
curl -sf -L https://unpub.example.internal/packages/path/versions/1.9.1.tar.gz -o /tmp/path.tar.gz
file /tmp/path.tar.gz   # gzip compressed data

# 4. verify it landed in S3
aws s3 ls s3://unpub-packages/path/

# 5. publish a package
cd ~/some-dart-pkg
dart pub publish --server=https://unpub.example.internal
```

Consume from another project:

```sh
export PUB_HOSTED_URL=https://unpub.example.internal
dart pub get
# or
flutter pub get
```

## 6. Local dev with Docker Compose

The repo ships a self-contained stack you can run end-to-end on a laptop:

```sh
docker compose -f docker-compose.dev.yml up -d minio minio-init dynamodb-local ddb-init
```

This stands up MinIO + DynamoDB Local and creates the bucket + both tables. Then point the compiled binary at them:

```sh
dart compile exe unpub_aws/example/server.dart -o /tmp/unpub-server

AWS_ACCESS_KEY_ID=minioadmin \
AWS_SECRET_ACCESS_KEY=minioadmin \
AWS_DEFAULT_REGION=ap-south-1 \
AWS_S3_ENDPOINT=http://localhost:9000 \
AWS_DDB_ENDPOINT=http://localhost:8000 \
UNPUB_BUCKET=unpub-packages \
UNPUB_TABLE=unpub-packages \
UNPUB_STATS_TABLE=unpub-stats \
UNPUB_OVERRIDE_UPLOADER=dev@local \
UNPUB_CACHE_UPSTREAM=true \
/tmp/unpub-server
```

Open `http://localhost:4000/` and you'll see the Vue UI. Search a `pub.dev` package, hit **Pull to cache**, watch it appear in the list and the bucket fill up.

> OrbStack note: the compose file clears `HTTP_PROXY` / `NO_PROXY` inside the init containers so the AWS CLI and `mc` can reach the in-network services. If you run on Docker Desktop you can drop those overrides.

Optional — UI development with hot reload:

```sh
cd unpub/web
npm install
npm run dev    # serves on :5173 with /webapi proxied to :4000
```

## 7. Operations

### Configuration knobs

All settable through Helm values (see `charts/unpub/values.yaml`) or directly via env vars on the container:

| Env var | Default | Meaning |
|---|---|---|
| `UNPUB_MODE` | `dynamo` | `dynamo` or `s3only` |
| `UNPUB_BUCKET` | `unpub-packages` | tarball bucket |
| `UNPUB_TABLE` | `unpub-packages` | metadata DDB table (dynamo mode) |
| `UNPUB_STATS_TABLE` | `unpub-stats` | daily-stats DDB table |
| `UNPUB_CACHE_UPSTREAM` | `false` | enable Athens-style pull-through cache |
| `UNPUB_UPSTREAM` | `https://pub.dev` | upstream registry |
| `UNPUB_OVERRIDE_UPLOADER` | unset | skip OAuth; record this email as uploader (dev/internal only) |
| `UNPUB_PORT` | `4000` | HTTP listen port |
| `AWS_REGION` / `AWS_DEFAULT_REGION` | unset (required) | AWS region |
| `AWS_S3_ENDPOINT` | AWS S3 | override for MinIO / local dev |
| `AWS_DDB_ENDPOINT` | AWS DDB | override for dynamodb-local |
| `AWS_ROLE_ARN`, `AWS_WEB_IDENTITY_TOKEN_FILE` | injected by IRSA webhook | IRSA chain |
| `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN` | unset | static-creds fallback |

### Observability

- `GET /metrics` — Prometheus text exposition (`Content-Type: text/plain; version=0.0.4`).
- Route labels are templates (`/api/packages/<name>` not the concrete name) so cardinality stays bounded.
- `unpub_uploads_total` / `unpub_downloads_total` are unlabelled by design — per-package telemetry lives in the `unpub-stats` DynamoDB table (`DynamoMetaStore.queryDailyDownloads()`).
- VMServiceScrape (`vmServiceScrape.enabled=true`) for clusters running the VictoriaMetrics Operator, otherwise pod-annotation scraping works for plain Prometheus.

### Outbound firewall

When `cacheUpstream: true`, the pod's egress allowlist needs to include:

- `pub.dev` — package metadata API + 302 redirects.
- `storage.googleapis.com` — `pub.dev` returns 302 here for the actual tarball bytes.
- `pub.dartlang.org` — legacy hostname some older Flutter SDKs still resolve.

(If you have a centralised proxy/firewall like Palo Alto NetSec, file the rule once and forget about it.)

### Scaling

- `unpub` is stateless. All state is in S3 + DynamoDB. Horizontal scale freely.
- The HPA in the chart defaults to 2-5 pods, CPU+memory at 75%. Tune via `hpa.*`.
- For `dynamo` mode, monitor DDB throttling. PAY_PER_REQUEST is fine for ~10k req/min sustained; switch to provisioned + autoscaling above that.

### Migrating between modes

Both modes share the same tarball key layout, so you only need to migrate **metadata**:

- `dynamo` → `s3only`: write a script that scans `unpub-packages` (DDB) and writes a `meta/packages/<name>/snap-00000001-*.json` + `current.json` per row.
- `s3only` → `dynamo`: opposite direction — list `meta/packages/*/current.json`, read each snapshot, `PutItem` into `unpub-packages` table.

A small Dart program using `DynamoMetaStore` + `S3MetaStore` directly can copy the catalogue in under a minute for a typical setup.

### Upgrading

Every Git tag matching `v*` rebuilds and pushes:

- `ghcr.io/rpsadarangani/unpub:<tag>` (multi-arch `linux/amd64` + `linux/arm64`)
- `oci://ghcr.io/rpsadarangani/charts/unpub:<tag-without-v>` (chart with `image.tag` pinned to the same tag)

Bump the chart with:

```sh
helm upgrade unpub oci://ghcr.io/rpsadarangani/charts/unpub --version 0.2.2 \
  -n devtools --reuse-values
```

Or commit the new tag to your GitOps repo.
