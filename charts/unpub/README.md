# unpub Helm chart

Self-hosted private Dart Pub server with S3 tarball storage, choice of DynamoDB or S3-only metadata, Athens-style pull-through caching of `pub.dev`, and Prometheus metrics.

The chart lives in this repo at [`charts/unpub`](./) and is also published as an OCI artifact:

```
oci://ghcr.io/rpsadarangani/charts/unpub
```

The container image referenced by the chart is published to:

```
ghcr.io/rpsadarangani/unpub
```

## TL;DR

```sh
# Pull + install from GHCR (OCI registry)
helm install unpub oci://ghcr.io/rpsadarangani/charts/unpub \
  --version 0.1.0 \
  --namespace devtools --create-namespace \
  --set aws.region=ap-south-1 \
  --set aws.bucket=ne-non-prod-unpub-packages \
  --set aws.ddbTable=unpub-packages \
  --set 'serviceAccount.annotations.eks\.amazonaws\.com/role-arn=arn:aws:iam::288761739962:role/unpub-non-prod-dso'

# Or install from a local checkout
helm install unpub ./charts/unpub -n devtools -f my-values.yaml
```

Point your Dart / Flutter clients at the resulting Service:

```bash
export PUB_HOSTED_URL=https://unpub.dso.uat-nebank.tools
dart pub get
```

## Requirements

- Kubernetes ≥ 1.27 (HPA `autoscaling/v2`, PDB `policy/v1`).
- Helm ≥ 3.8 (OCI registry support).
- An S3 bucket for tarballs (and, in `mode: s3only`, the metadata too).
- A DynamoDB table (when `mode: dynamo`). A second optional `unpub-stats` table for daily per-version counters.
- An IAM role for the pod with `s3:PutObject`/`s3:GetObject`/`s3:ListBucket` on the bucket and (for the dynamo mode) `dynamodb:GetItem`/`PutItem`/`UpdateItem`/`Query` on the two tables. Wire it up either via IRSA (`serviceAccount.annotations`) or static keys delivered through an `ExternalSecret`.

## Modes

| `mode` | Metadata store | Tarball store | When to pick |
|---|---|---|---|
| `dynamo` *(default)* | DynamoDB (`name` PK + `gsi_updated` / `gsi_download`) + optional daily-stats table | S3 | Production. Single-digit ms metadata reads, atomic counters, indexed listing. |
| `s3only` | S3 (Iceberg-style: immutable snapshots + CAS-swapped pointer + per-version files + global catalog) | S3 | Zero non-S3 infra. Cheapest. Listing/sort is `O(N)` reads — fine up to a few thousand packages. |

Both modes share the same S3 bucket layout for tarballs (`packages/<name>/<name>-<version>.tar.gz`).

## Upstream caching

`cacheUpstream: true` enables Athens-style behaviour: when a package isn't in the local store, unpub fetches it from `upstream` (default `https://pub.dev`), streams the synthetic response to the client immediately, persists every version to the metadata store in the background, and writes the tarball into S3 on tarball requests. Concurrent first-fetches for the same package are deduped through in-memory inflight maps. Set `cacheUpstream: false` to revert to plain `302 Found` redirects.

## Authentication options

### IRSA (recommended)

```yaml
serviceAccount:
  create: true
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::288761739962:role/unpub-non-prod-dso
```

The pod-identity webhook injects `AWS_ROLE_ARN` + `AWS_WEB_IDENTITY_TOKEN_FILE`. unpub's `AwsCredentialChain` calls STS `AssumeRoleWithWebIdentity` and refreshes the credential at 80% of the token TTL.

### Static keys via ExternalSecret

```yaml
serviceAccount:
  create: true
externalSecret:
  enabled: true
  apiVersion: external-secrets.io/v1beta1   # or external-secrets.io/v1 on newer clusters
  secretStoreRef:
    name: aws-secretsmanager
    kind: ClusterSecretStore
  data:
    - envVar: AWS_ACCESS_KEY_ID
      remoteRef:
        key: /non-prod-dso/infra/unpub-aws-creds
        property: access_key_id
    - envVar: AWS_SECRET_ACCESS_KEY
      remoteRef:
        key: /non-prod-dso/infra/unpub-aws-creds
        property: secret_access_key
```

## Ingress vs Istio

Either of the toggles works in isolation — leave both off in environments that publish the Service directly via an internal-only NLB.

```yaml
ingress:
  enabled: true
  className: nginx
  host: unpub.dso.example.com
  tls:
    - hosts: [unpub.dso.example.com]
      secretName: unpub-tls
```

```yaml
istio:
  enabled: true
  gateway: istio-system/internal-gateway
  host: unpub.dso.nebank.tools
```

## Observability

The pod always exposes Prometheus metrics on `:4000/metrics`. The chart ships two ways to scrape them:

| `serviceMonitor.enabled` | Prometheus Operator (kube-prometheus-stack) picks it up automatically |
| `podAnnotations.prometheus.io/scrape` | Vanilla pod-scrape annotations for the plain-Prometheus configs that look at them |

Key series:

- `unpub_http_requests_total{route, method, status}` — counter
- `unpub_http_request_duration_seconds_bucket{route, method, le}` — histogram
- `unpub_upstream_cache_hits_total{kind}` / `unpub_upstream_cache_misses_total{kind}` — `kind` is `metadata` or `tarball`
- `unpub_upstream_fetch_duration_seconds_bucket{kind, le}`
- `unpub_upstream_dedup_hits_total{kind}`
- `unpub_inflight_upstream_metadata` / `unpub_inflight_upstream_tarballs` — gauges
- `unpub_uploads_total{package}` / `unpub_downloads_total{package}`

Route labels are templates (e.g. `/api/packages/<name>`) so the series count stays bounded as the catalogue grows.

## Values reference

| Key | Default | Notes |
|---|---|---|
| `image.repository` | `ghcr.io/rpsadarangani/unpub` | |
| `image.tag` | `""` (falls back to `Chart.appVersion`) | |
| `mode` | `dynamo` | `dynamo` or `s3only` |
| `replicaCount` | `2` | |
| `cacheUpstream` | `true` | Athens-style pull-through |
| `upstream` | `https://pub.dev` | |
| `aws.region` | `ap-south-1` | |
| `aws.bucket` | `unpub-packages` | |
| `aws.ddbTable` | `unpub-packages` | only in `dynamo` mode |
| `aws.ddbStatsTable` | `unpub-stats` | optional daily-stats table |
| `aws.s3Endpoint` / `aws.ddbEndpoint` | unset | override for local dev / non-AWS S3 |
| `serviceAccount.create` | `true` | |
| `serviceAccount.annotations` | `{}` | put your IRSA ARN here |
| `externalSecret.enabled` | `false` | |
| `service.type` | `ClusterIP` | |
| `ingress.enabled` | `false` | |
| `istio.enabled` | `false` | |
| `hpa.enabled` | `true` | targets 75% CPU + memory |
| `hpa.apiVersionOverride` | `""` (uses `autoscaling/v2`) | |
| `podDisruptionBudget.enabled` | `true` | `minAvailable: 1` |
| `serviceMonitor.enabled` | `false` | Prometheus Operator |
| `affinity` | prefer Karpenter spot | |
| `containerSecurityContext` | non-root, read-only rootfs, drop ALL caps | |

See [`values.yaml`](./values.yaml) for the full set.

## Local dev

The repo root ships a Docker Compose stack (`docker-compose.dev.yml`) that boots MinIO + DynamoDB Local + the bucket/table initialisers. Point the chart at it with:

```yaml
aws:
  region: ap-south-1
  s3Endpoint: http://host.docker.internal:9000
  ddbEndpoint: http://host.docker.internal:8000
externalSecret:
  enabled: false
env:
  AWS_ACCESS_KEY_ID: minioadmin
  AWS_SECRET_ACCESS_KEY: minioadmin
  UNPUB_OVERRIDE_UPLOADER: dev@local
```

## Releases

Every Git tag matching `v*` rebuilds and pushes:

- `ghcr.io/rpsadarangani/unpub:<tag>` (multi-arch: `linux/amd64`, `linux/arm64`)
- `oci://ghcr.io/rpsadarangani/charts/unpub:<tag without v>` (chart with `appVersion` pinned to the same tag, and `image.tag` pinned in `values.yaml` so a `helm install` always uses a matching image)

Pull a specific version of the chart:

```sh
helm pull oci://ghcr.io/rpsadarangani/charts/unpub --version 0.1.0
```
