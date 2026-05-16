# Contributing

Thanks for thinking of contributing. This fork is small and the bar is "does it work and is it observable?" — not "perfect."

## Development setup

You will need:

- Dart 3.5+ (Flutter installs a compatible Dart). Install via [`mise`](https://mise.jdx.dev/) (`mise use flutter@latest`) or directly from [dart.dev](https://dart.dev/get-dart).
- Docker (Docker Desktop, OrbStack, Colima — all fine).
- An OCI-aware Helm 3.8+ if you plan to touch the chart.

Clone and resolve deps:

```sh
git clone https://github.com/rpsadarangani/unpub
cd unpub
(cd unpub && dart pub get) && (cd unpub_aws && dart pub get)
```

Boot the local infra (MinIO + DynamoDB Local):

```sh
docker compose -f docker-compose.dev.yml up -d minio minio-init dynamodb-local ddb-init
```

Compile + run the server:

```sh
dart compile exe unpub_aws/example/server.dart -o /tmp/unpub-server

AWS_ACCESS_KEY_ID=minioadmin \
AWS_SECRET_ACCESS_KEY=minioadmin \
AWS_DEFAULT_REGION=ap-south-1 \
AWS_S3_ENDPOINT=http://localhost:9000 \
AWS_DDB_ENDPOINT=http://localhost:8000 \
UNPUB_BUCKET=unpub-packages \
UNPUB_TABLE=unpub-packages \
UNPUB_OVERRIDE_UPLOADER=dev@local \
UNPUB_CACHE_UPSTREAM=true \
/tmp/unpub-server
```

Then publish or consume a package against `http://localhost:4000`.

## Reporting issues

All discussion happens on GitHub:

- **Bugs / feature requests** — [open an issue](https://github.com/rpsadarangani/unpub/issues/new/choose).
- **Questions / "how do I…?"** — [GitHub Discussions](https://github.com/rpsadarangani/unpub/discussions).
- **Security** — [private vulnerability report](https://github.com/rpsadarangani/unpub/security/advisories/new) (see [SECURITY.md](./SECURITY.md)).

No email channel. Please don't DM the maintainer privately about issues that can be tracked in the open.

## Sending a PR

1. Open an issue first if the change is large or design-impacting.
2. Branch from `master`. Keep the change small and focused.
3. Make sure CI is green (`dart analyze` for both packages, `helm lint` + `helm template` for the chart).
4. If you touched the chart, bump its `version` in `Chart.yaml`. If you touched the public Dart API, bump the package version in the relevant `pubspec.yaml`.
5. Conventional commit prefixes are appreciated: `feat:`, `fix:`, `docs:`, `chore:`, `ci:`, `refactor:`, `test:`.
6. Add a brief `## Test plan` to the PR description.

## Coding style

- Run `dart format` before pushing.
- Don't add comments that just restate the code. Comment the **why**, especially for non-obvious things (e.g. DynamoDB reserved-word aliasing, `whenComplete` pitfalls, S3 conditional-write retries).
- Keep functions small; prefer explicit `try/finally` over chained `.whenComplete()` callbacks when both register/cleanup state.
- For DynamoDB / S3 operations, always alias attribute names (`#name`, `#download`, …) — many keys collide with reserved words.

## Releasing

Releases are tag-driven. To cut one:

```sh
git checkout master
git pull
git tag -a v0.X.Y -m "v0.X.Y: short summary"
git push origin v0.X.Y
```

The `release` workflow builds and pushes:

- `ghcr.io/rpsadarangani/unpub:v0.X.Y` (multi-arch).
- `oci://ghcr.io/rpsadarangani/charts/unpub:0.X.Y` (chart with `image.tag` pinned to `v0.X.Y`).

Then create a GitHub release on the tag with notes via `gh release create`.

## Code of conduct

By participating, you agree to abide by the [Code of Conduct](./CODE_OF_CONDUCT.md).
