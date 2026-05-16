# syntax=docker/dockerfile:1.6

# ---------- builder ----------
FROM dart:stable AS builder

WORKDIR /src

# Copy workspace metadata first for better caching.
COPY unpub/pubspec.yaml unpub/pubspec.lock* unpub/
COPY unpub_aws/pubspec.yaml unpub_aws/pubspec.lock* unpub_aws/
COPY unpub_auth/pubspec.yaml unpub_auth/pubspec.lock* unpub_auth/
COPY unpub_web/pubspec.yaml unpub_web/pubspec.lock* unpub_web/

# Now copy source and resolve.
COPY . .

RUN cd unpub && dart pub get && \
    cd ../unpub_aws && dart pub get

# Compile the unified server (mode-selectable via --mode dynamo|s3only).
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
