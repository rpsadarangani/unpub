# syntax=docker/dockerfile:1.6

# ---------- web ----------
# Build the Vite + Vue 3 + TypeScript UI and bake it into a Dart constant
# the server can serve at `/`. `vite-plugin-singlefile` inlines all JS/CSS
# into one index.html, then `build-to-dart.mjs` wraps it as a Dart string.
# Node 24 LTS: Node 20 is EOL and misses the Oct 2026 security release
# (CVE-2026-111497 et al.). Digest bumped by Dependabot (docker ecosystem).
FROM node:24.22.1-bookworm-slim@sha256:55fb5f5a527ea2c5c4a95f963e48ef90aa38c7b346054fdc8ee9957a2b55d205 AS web

WORKDIR /repo

COPY unpub/web/ /repo/unpub/web/
RUN corepack enable

WORKDIR /repo/unpub/web
RUN if [ -f pnpm-lock.yaml ]; then pnpm install --frozen-lockfile; \
    elif [ -f package-lock.json ]; then npm ci; \
    else npm install; fi
RUN npm run build
# build-to-dart.mjs writes ../lib/src/static/index.html.dart, i.e.
# /repo/unpub/lib/src/static/index.html.dart.

# ---------- builder ----------
FROM dart:stable AS builder

WORKDIR /src

COPY unpub/pubspec.yaml unpub/pubspec.lock* unpub/
COPY unpub_aws/pubspec.yaml unpub_aws/pubspec.lock* unpub_aws/
COPY unpub_auth/pubspec.yaml unpub_auth/pubspec.lock* unpub_auth/
COPY unpub_web/pubspec.yaml unpub_web/pubspec.lock* unpub_web/

COPY . .

# Replace the in-tree UI constant with the freshly built TS bundle.
COPY --from=web /repo/unpub/lib/src/static/index.html.dart \
                unpub/lib/src/static/index.html.dart

WORKDIR /src/unpub
RUN dart pub get
WORKDIR /src/unpub_aws
RUN dart pub get
WORKDIR /src

RUN mkdir -p /out && dart compile exe unpub_aws/example/server.dart -o /out/unpub-server

# ---------- runtime ----------
# Chainguard glibc-dynamic: glibc + CA certs only, nonroot (65532), no shell
# or package manager. dumb-init comes from Wolfi so it links the same glibc.
# Digests are bumped by Dependabot (docker ecosystem).
FROM cgr.dev/chainguard/wolfi-base:latest@sha256:bc76fa39ddd1482dd56a761b3331e03ba8f0e093ebb525618a56d014b480da88 AS init
RUN apk add --no-cache dumb-init

FROM cgr.dev/chainguard/glibc-dynamic:latest@sha256:3f1283dc2a6a48c25cd2e1c7730a871b19b721975240e108e0d6a73b555a3a20

COPY --from=init /usr/bin/dumb-init /usr/bin/dumb-init
COPY --from=builder /out/unpub-server /usr/local/bin/unpub-server

ENV UNPUB_PORT=4000
EXPOSE 4000

USER 65532:65532

ENTRYPOINT ["/usr/bin/dumb-init", "--"]
CMD ["/usr/local/bin/unpub-server"]
