# syntax=docker/dockerfile:1.6

# ---------- web ----------
# Build the Vite + Vue 3 + TypeScript UI and bake it into a Dart constant
# the server can serve at `/`. `vite-plugin-singlefile` inlines all JS/CSS
# into one index.html, then `build-to-dart.mjs` wraps it as a Dart string.
FROM node:20-bookworm-slim AS web

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

RUN cd unpub && dart pub get && \
    cd ../unpub_aws && dart pub get

RUN mkdir -p /out && dart compile exe unpub_aws/example/server.dart -o /out/unpub-server

# ---------- runtime ----------
FROM debian:bookworm-slim

RUN apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates dumb-init && \
    rm -rf /var/lib/apt/lists/*

COPY --from=builder /out/unpub-server /usr/local/bin/unpub-server

ENV UNPUB_PORT=4000
EXPOSE 4000

ENTRYPOINT ["/usr/bin/dumb-init", "--"]
CMD ["/usr/local/bin/unpub-server"]
