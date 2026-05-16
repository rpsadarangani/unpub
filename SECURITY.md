# Security policy

## Supported versions

The project follows the latest `v0.x` release on `master`. Older tags are not patched. When a CVE-class issue lands, fixes go into the next tagged release.

## Reporting a vulnerability

**Please do not open a public GitHub issue for security reports.**

Use GitHub's private vulnerability reporting:

- https://github.com/rpsadarangani/unpub/security/advisories/new

If GitHub private reporting is unavailable for some reason, open an issue marked `security` and request that the maintainer move the discussion to a private advisory — but do not include exploitation details in the public issue body.

Include in your report:

- A description of the issue and its impact.
- Steps to reproduce or a proof-of-concept (a small Dart snippet or `curl` command is great).
- The commit hash or release tag you're testing against.
- Whether you'd like to be credited in the eventual advisory and how.

Expected response timeline:

- Acknowledgement within **72 hours**.
- Severity assessment within **7 days**.
- Fix release for **High** / **Critical** issues within **30 days** where possible.

Once a fix is shipped we'll cut a GitHub Security Advisory crediting you (if you opted in).

## Scope

In scope:

- Vulnerabilities in the unpub server itself (auth bypass, path traversal, request smuggling, malformed-input crashes, etc.).
- Vulnerabilities in the AWS-backed code paths (SigV4 signer, IRSA credential handling, S3 conditional-write logic, DynamoDB query construction).
- Cache-poisoning issues in the upstream-caching path.
- Issues that allow a low-privileged client to escalate to publishing as another uploader.

Out of scope:

- Findings against pub.dev or other upstream registries.
- Denial-of-service through plain volumetric attack (configure your own ingress / rate-limiting).
- Issues that require an attacker to already have AWS IAM credentials or cluster access.
- Reports that boil down to misconfiguration of `cacheUpstream`, `uploadValidator`, or other knobs documented in [`charts/unpub/README.md`](./charts/unpub/README.md).

Thanks for keeping unpub safe.
