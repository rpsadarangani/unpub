# Changelog

All notable changes to this fork are documented here. See [GitHub releases](https://github.com/rpsadarangani/unpub/releases) for binary and chart artifacts.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Private upstreams (`UNPUB_UPSTREAM_<n>_URL` + `_TOKEN` or `_USERNAME`/`_PASSWORD`; chart `extraUpstreams`), consulted before `UNPUB_UPSTREAM`; only a 404 falls through. Auth for the primary upstream via `UNPUB_UPSTREAM_TOKEN` / `_USERNAME` / `_PASSWORD`. Credentials never follow cross-host redirects.
- `UNPUB_UPSTREAM_METADATA_TTL` (chart `upstreamMetadataTtlSeconds`, default 600s) and chart `publicUrl`.

### Fixed
- Mirrored package metadata was never refreshed, so new upstream versions never appeared; it is now re-checked per TTL and merged with the cache.
- Upstream metadata persistence swallowed errors, wrote versions concurrently (random `latestVersion`) and re-appended versions on refresh (duplicates). Now only missing versions are written, in order, with errors logged; duplicates in existing data are hidden when serving.
- Upstream URLs with a path prefix lost the prefix; tarballs are fetched from the upstream's `archive_url`.
- npm advisories in `unpub/web` (vite 8.3.5, vue 3.5.44, postcss, nanoid, source-map-js, brace-expansion).

### Changed
- Runtime image is `cgr.dev/chainguard/glibc-dynamic` (nonroot, digest-pinned); chart sets `seccompProfile: RuntimeDefault` and `runAsGroup`.

## [0.1.0] - 2026-05-16

First AWS-native release of this fork.

### Added

- **`DynamoMetaStore`** — `MetaStore` on DynamoDB with atomic `download` counters, GSI-backed listing/sort (`gsi_updated`, `gsi_download`), reserved-word-safe attribute aliasing, and an optional `unpub-stats` table for per-day, per-version download counters.
- **`S3MetaStore`** — Iceberg-style metadata layout: immutable `snap-N-<uuid>.json` snapshots + CAS-swapped `current.json` pointer + per-version files + global `catalog/index.json` + append-only `meta/downloads/<date>/` events (with `aggregateDailyDownloads` / `persistDailyStats` / `readDailyStats` APIs).
- **`AwsCredentialChain`** — explicit override → IRSA / STS `AssumeRoleWithWebIdentity` (auto-refresh at 80% TTL) → static env vars.
- **`PackageStore.exists()`** + `S3FileStore` `statObject`-based override, used by the cache-on-miss path.
- **Athens-style upstream caching** (`App.cacheUpstream`) — cache misses fetch from `upstream`, persist into your store, dedupe concurrent first-fetches.
- **Prometheus metrics** at `GET /metrics` — counters/histograms/gauges with low-cardinality route templating, upstream cache stats, upload/download counters. No new deps.
- **Unified server entrypoint** at `unpub_aws/example/server.dart`, mode-selectable via `--mode dynamo|s3only` / `UNPUB_MODE`.
- **Docker Compose dev stack** (`docker-compose.dev.yml`) — MinIO + DynamoDB Local + bucket/table init with OrbStack-friendly `NO_PROXY` overrides.
- **Helm chart** (`charts/unpub`) — Deployment / Service / HPA / PDB / SA (IRSA-ready) / optional Istio `VirtualService`, `ServiceMonitor`, `ExternalSecret` (`v1`/`v1beta1` apiVersion knob).
- **CI** — `dart analyze` + `helm lint`/`template` on every push/PR (`.github/workflows/test.yml`). Tag `v*` triggers multi-arch Docker push to `ghcr.io/rpsadarangani/unpub` and OCI Helm push to `oci://ghcr.io/rpsadarangani/charts/unpub` (`.github/workflows/release.yml`).

### Changed

- SDK constraints bumped to `>=2.17.0 <4.0.0` (was `>=2.12.0 <3.0.0`) so the package builds on Dart 3.x.
- `S3FileStore.download` rewritten as `async*` (was `dart:cli` `waitFor`).
- `AwsCredentials` no longer probes ECS task-role credentials at construction time — use `AwsCredentialChain` for dynamic resolution.

[Unreleased]: https://github.com/rpsadarangani/unpub/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/rpsadarangani/unpub/releases/tag/v0.1.0
