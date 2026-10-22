import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:collection/collection.dart' show IterableExtension;
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:googleapis/oauth2/v2.dart';
import 'package:mime/mime.dart';
import 'package:http_parser/http_parser.dart';
import 'package:shelf_cors_headers/shelf_cors_headers.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:pub_semver/pub_semver.dart' as semver;
import 'package:archive/archive.dart';
import 'package:unpub/src/models.dart';
import 'package:unpub/unpub_api/lib/models.dart';
import 'package:unpub/src/meta_store.dart';
import 'package:unpub/src/metrics.dart';
import 'package:unpub/src/package_store.dart';
import 'package:unpub/src/upstream.dart';
import 'utils.dart';
import 'static/index.html.dart' as index_html;
import 'static/main.dart.js.dart' as main_dart_js;

part 'app.g.dart';

class App {
  static const proxyOriginHeader = "proxy-origin";

  /// meta information store
  final MetaStore metaStore;

  /// package(tarball) store
  final PackageStore packageStore;

  /// upstream url, default: https://pub.dev
  final String upstream;

  /// http(s) proxy to call googleapis (to get uploader email)
  final String? googleapisProxy;
  final String? overrideUploaderEmail;

  /// A forward proxy uri
  final Uri? proxy_origin;

  /// validate if the package can be published
  ///
  /// for more details, see: https://github.com/bytedance/unpub#package-validator
  final Future<void> Function(
      Map<String, dynamic> pubspec, String uploaderEmail)? uploadValidator;

  /// When `true`, on a cache miss the server fetches the package metadata
  /// (and tarballs) from [upstream], stores them locally, and serves the
  /// cached copy on subsequent requests — Athens-style pull-through caching.
  /// When `false`, cache misses are served by HTTP `302` to the upstream
  /// (original behaviour).
  final bool cacheUpstream;

  /// Email recorded as the "uploader" on packages mirrored from upstream.
  /// Defaults to `upstream@<host>`.
  final String? upstreamUploaderEmail;

  /// Bearer token sent to [upstream] (private registries: Artifactory,
  /// Cloudsmith, another unpub, …). Takes precedence over basic auth.
  final String? upstreamToken;

  /// Basic-auth credentials sent to [upstream] when [upstreamToken] is unset.
  final String? upstreamUsername;
  final String? upstreamPassword;

  /// Additional (typically private) upstreams consulted before [upstream].
  /// A package found in one of these is never looked up on [upstream], and
  /// only a 404 falls through to the next one — this keeps private package
  /// names from being shadowed by a public package (dependency confusion).
  final List<Upstream> extraUpstreams;

  /// Name of the primary [upstream] in pinned URLs (`/u/<name>/`).
  final String upstreamName;

  /// [extraUpstreams] followed by the primary [upstream], in lookup order.
  late final List<Upstream> _upstreams;

  /// Request-context key holding the [Upstream] a `/u/<name>/` request is
  /// pinned to.
  static const _pinKey = 'unpub.upstream';

  /// How long mirrored package metadata is served from the local store
  /// before it is re-checked against [upstream] for new versions.
  final Duration upstreamMetadataTtl;

  /// HTTP client used to fetch from [upstream]. Override in tests.
  final http.Client _upstreamClient;

  /// Last successful upstream metadata refresh per package (this replica).
  final Map<String, DateTime> _lastUpstreamRefresh = {};

  /// `archive_url` advertised by upstream, keyed by `<name>@<version>`.
  final Map<String, String> _upstreamArchiveUrls = {};

  /// Versions this replica has queued or written to [metaStore], keyed by
  /// package name, so a refresh that read the store before an earlier
  /// background persist landed doesn't write them a second time.
  final Map<String, Set<String>> _persistQueued = {};

  /// In-flight upstream metadata fetches keyed by package name — dedupes
  /// thundering herds so N concurrent first-fetches collapse to 1 upstream call.
  final Map<String, Future<UnpubPackage?>> _inflightMeta = {};

  /// In-flight upstream tarball fetches keyed by `<name>@<version>`.
  final Map<String, Future<List<int>>> _inflightTarballs = {};

  /// Prometheus metrics registry, exposed at `GET /metrics`.
  late final Metrics metrics;

  late final Counter _httpRequestsTotal;
  late final Histogram _httpRequestDuration;
  late final Counter _upstreamCacheHits;
  late final Counter _upstreamCacheMisses;
  late final Counter _upstreamDedupHits;
  late final Histogram _upstreamFetchDuration;
  late final Counter _uploadsTotal;
  late final Counter _downloadsTotal;
  late final Gauge _inflightMetaGauge;
  late final Gauge _inflightTarballGauge;

  App({
    required this.metaStore,
    required this.packageStore,
    this.upstream = 'https://pub.dev',
    this.googleapisProxy,
    this.overrideUploaderEmail,
    this.uploadValidator,
    this.proxy_origin,
    this.cacheUpstream = false,
    this.upstreamUploaderEmail,
    this.upstreamToken,
    this.upstreamUsername,
    this.upstreamPassword,
    this.upstreamMetadataTtl = const Duration(minutes: 10),
    this.extraUpstreams = const [],
    this.upstreamName = 'pub',
    http.Client? upstreamClient,
    Metrics? metrics,
  }) : _upstreamClient = upstreamClient ?? http.Client() {
    _upstreams = [
      ...extraUpstreams,
      Upstream(upstream,
          name: upstreamName,
          token: upstreamToken,
          username: upstreamUsername,
          password: upstreamPassword),
    ];
    final names = _upstreams.map((u) => u.name).toList();
    if (names.toSet().length != names.length) {
      throw ArgumentError('upstream names must be unique: $names');
    }
    this.metrics = metrics ?? Metrics();
    _registerMetrics();
  }

  void _registerMetrics() {
    _httpRequestsTotal = metrics.counter(
      name: 'unpub_http_requests_total',
      help: 'Total HTTP requests served by unpub.',
      labelNames: ['route', 'method', 'status'],
    );
    _httpRequestDuration = metrics.histogram(
      name: 'unpub_http_request_duration_seconds',
      help: 'HTTP request handler latency in seconds.',
      labelNames: ['route', 'method'],
    );
    _upstreamCacheHits = metrics.counter(
      name: 'unpub_upstream_cache_hits_total',
      help:
          'Cache-on-miss requests where the package was already in the local store.',
      labelNames: ['kind'],
    );
    _upstreamCacheMisses = metrics.counter(
      name: 'unpub_upstream_cache_misses_total',
      help: 'Cache-on-miss requests where unpub had to fetch from upstream.',
      labelNames: ['kind'],
    );
    _upstreamDedupHits = metrics.counter(
      name: 'unpub_upstream_dedup_hits_total',
      help:
          'Concurrent fetches that were collapsed onto an in-flight upstream call.',
      labelNames: ['kind'],
    );
    _upstreamFetchDuration = metrics.histogram(
      name: 'unpub_upstream_fetch_duration_seconds',
      help: 'Time spent fetching a package from the upstream registry.',
      labelNames: ['kind'],
    );
    // Per-package labels would explode cardinality once the catalogue grows.
    // Total counters here; per-package telemetry lives in the `unpub-stats`
    // DynamoDB table (see DynamoMetaStore.queryDailyDownloads).
    _uploadsTotal = metrics.counter(
      name: 'unpub_uploads_total',
      help: 'Successful publish requests (excluding upstream mirrors).',
    );
    _downloadsTotal = metrics.counter(
      name: 'unpub_downloads_total',
      help: 'Tarball downloads served from the local store.',
    );
    _inflightMetaGauge = metrics.gauge(
      name: 'unpub_inflight_upstream_metadata',
      help: 'Concurrent upstream metadata fetches currently in flight.',
    );
    _inflightTarballGauge = metrics.gauge(
      name: 'unpub_inflight_upstream_tarballs',
      help: 'Concurrent upstream tarball fetches currently in flight.',
    );
  }

  static shelf.Response _okWithJson(Map<String, dynamic> data) =>
      shelf.Response.ok(
        json.encode(data),
        headers: {
          HttpHeaders.contentTypeHeader: ContentType.json.mimeType,
          'Access-Control-Allow-Origin': '*'
        },
      );

  static shelf.Response _successMessage(String message) => _okWithJson({
        'success': {'message': message}
      });

  static shelf.Response _badRequest(String message,
          {int status = HttpStatus.badRequest}) =>
      shelf.Response(
        status,
        headers: {HttpHeaders.contentTypeHeader: ContentType.json.mimeType},
        body: json.encode({
          'error': {'message': message}
        }),
      );

  http.Client? _googleapisClient;

  String _resolveUrl(shelf.Request req, String reference) {
    if (proxy_origin != null) {
      return proxy_origin!.resolve(reference).toString();
    }
    String? proxyOriginInHeader = req.headers[proxyOriginHeader];
    if (proxyOriginInHeader != null) {
      return Uri.parse(proxyOriginInHeader).resolve(reference).toString();
    }
    return req.requestedUri.resolve(reference).toString();
  }

  Future<String> _getUploaderEmail(shelf.Request req) async {
    if (overrideUploaderEmail != null) return overrideUploaderEmail!;

    var authHeader = req.headers[HttpHeaders.authorizationHeader];
    if (authHeader == null) throw 'missing authorization header';

    var token = authHeader.split(' ').last;

    if (_googleapisClient == null) {
      if (googleapisProxy != null) {
        _googleapisClient = IOClient(HttpClient()
          ..findProxy = (url) => HttpClient.findProxyFromEnvironment(url,
              environment: {"https_proxy": googleapisProxy!}));
      } else {
        _googleapisClient = http.Client();
      }
    }

    var info =
        await Oauth2Api(_googleapisClient!).tokeninfo(accessToken: token);
    if (info.email == null) throw 'fail to get google account email';
    return info.email!;
  }

  Future<HttpServer> serve([String host = '0.0.0.0', int port = 4000]) async {
    var server = await shelf_io.serve(handler, host, port);
    return server;
  }

  /// The full request handler (middleware + routes) that [serve] runs.
  shelf.Handler get handler {
    return const shelf.Pipeline()
        .addMiddleware(corsHeaders())
        .addMiddleware(shelf.logRequests())
        .addMiddleware(_metricsMiddleware())
        .addMiddleware(_upstreamPinMiddleware())
        .addHandler((req) async {
      if (req.url.path == 'metrics') {
        return shelf.Response.ok(
          metrics.render(),
          headers: {
            HttpHeaders.contentTypeHeader:
                'text/plain; version=0.0.4; charset=utf-8',
          },
        );
      }
      // Return 404 by default
      // https://github.com/google/dart-neats/issues/1
      var res = await router.call(req);
      return res;
    });
  }

  /// Read-only routes reachable under `/u/<upstream>/`.
  static final _pinnableRoutes = [
    RegExp(r'^api/packages/[^/]+$'),
    RegExp(r'^api/packages/[^/]+/versions/[^/]+$'),
    RegExp(r'^packages/[^/]+/versions/[^/]+\.tar\.gz$'),
  ];

  /// Serves `/u/<name>/...` as the normal pub API pinned to one upstream, so
  /// a pubspec can choose the source per dependency
  /// (`hosted: https://unpub.example/u/<name>/`). Only package metadata and
  /// tarball reads are available there; publishing stays on the root URL.
  shelf.Middleware _upstreamPinMiddleware() {
    return (inner) {
      return (req) {
        final segments = req.url.pathSegments;
        if (segments.isEmpty || segments.first != 'u') return inner(req);
        final pin = segments.length > 1
            ? _upstreams.firstWhereOrNull((u) => u.name == segments[1])
            : null;
        if (pin == null || !cacheUpstream) {
          return shelf.Response.notFound('unknown upstream');
        }
        final rest = segments.skip(2).join('/');
        if (req.method != 'GET' ||
            !_pinnableRoutes.any((r) => r.hasMatch(rest))) {
          return shelf.Response.notFound('Not Found');
        }
        return inner(req.change(
          path: 'u/${pin.name}',
          context: {_pinKey: pin},
        ));
      };
    };
  }

  Upstream? _pinOf(shelf.Request req) => req.context[_pinKey] as Upstream?;

  /// `/u/<name>` for pinned requests, so URLs we hand out keep the pin.
  String _pinPrefix(shelf.Request req) {
    final pin = _pinOf(req);
    return pin == null ? '' : '/u/${pin.name}';
  }

  /// Records `unpub_http_requests_total` + `unpub_http_request_duration_seconds`
  /// per route. The route label is a low-cardinality template
  /// (`/api/packages/<name>` rather than `/api/packages/path`), so that the
  /// metric series count stays bounded as the package catalogue grows.
  shelf.Middleware _metricsMiddleware() {
    return (inner) {
      return (req) async {
        // Skip self-instrumentation to avoid double counting `/metrics` hits.
        if (req.url.path == 'metrics') return inner(req);
        final route = _routeTemplate(req.url.path);
        final method = req.method;
        final sw = Stopwatch()..start();
        shelf.Response res;
        try {
          res = await inner(req);
        } finally {
          sw.stop();
          _httpRequestDuration
              .observe(sw.elapsedMicroseconds / 1e6, [route, method]);
        }
        _httpRequestsTotal.inc([route, method, res.statusCode.toString()]);
        return res;
      };
    };
  }

  /// Map concrete request paths to a low-cardinality label.
  String _routeTemplate(String path) {
    final segments = path.split('/').where((s) => s.isNotEmpty).toList();
    if (segments.length >= 2 && segments.first == 'u') {
      final known = _upstreams.any((u) => u.name == segments[1]);
      return '/u/${known ? segments[1] : '<unknown>'}'
          '${_routeTemplate(segments.skip(2).join('/'))}';
    }
    final p = path.startsWith('/') ? path : '/$path';
    if (p.startsWith('/api/packages/versions/new')) {
      return '/api/packages/versions/new';
    }
    if (p.startsWith('/api/packages/versions/newUpload')) {
      return '/api/packages/versions/newUpload';
    }
    if (p == '/api/packages/versions/newUploadFinish') return p;
    if (p.startsWith('/api/packages/')) {
      final parts = p.split('/');
      // /api/packages/<name>/versions/<version>
      if (parts.length >= 6 && parts[4] == 'versions') {
        return '/api/packages/<name>/versions/<version>';
      }
      // /api/packages/<name>/uploaders[/<email>]
      if (parts.length >= 5 && parts[4] == 'uploaders') {
        return '/api/packages/<name>/uploaders';
      }
      return '/api/packages/<name>';
    }
    if (p.startsWith('/packages/') && p.endsWith('.tar.gz')) {
      return '/packages/<name>/versions/<version>.tar.gz';
    }
    if (p.startsWith('/badge/')) return '/badge/<kind>/<name>';
    if (p == '' || p == '/') return '/';
    return p; // static assets / unknown — bounded by file count
  }

  Map<String, dynamic> _versionToJson(UnpubVersion item, shelf.Request req) {
    var name = item.pubspec['name'] as String;
    var version = item.version;
    return {
      'archive_url': _resolveUrl(
          req, '${_pinPrefix(req)}/packages/$name/versions/$version.tar.gz'),
      'pubspec': item.pubspec,
      'version': version,
    };
  }

  bool isPubClient(shelf.Request req) {
    var ua = req.headers[HttpHeaders.userAgentHeader];
    print(ua);
    return ua != null && ua.toLowerCase().contains('dart pub');
  }

  Router get router => _$AppRouter(this);

  @Route.get('/api/packages/<name>')
  Future<shelf.Response> getVersions(shelf.Request req, String name) async {
    var package = await _resolvePackage(name, pin: _pinOf(req));
    if (package == null) {
      if (_pinOf(req) != null) return shelf.Response.notFound('Not Found');
      return shelf.Response.found(
          Uri.parse(upstream).resolve('/api/packages/$name').toString());
    }

    // Older caches may hold the same version more than once (a forced
    // refresh used to re-append every version); serve each one once.
    final unique = <String, UnpubVersion>{
      for (final v in package.versions) v.version: v,
    }.values.toList();
    unique.sort((a, b) {
      return semver.Version.prioritize(
          semver.Version.parse(a.version), semver.Version.parse(b.version));
    });

    var versionMaps = unique.map((item) => _versionToJson(item, req)).toList();

    return _okWithJson({
      'name': name,
      'latest': versionMaps.last, // TODO: Exclude pre release
      'versions': versionMaps,
    });
  }

  @Route.get('/api/packages/<name>/versions/<version>')
  Future<shelf.Response> getVersion(
      shelf.Request req, String name, String version) async {
    // Important: + -> %2B, should be decoded here
    try {
      version = Uri.decodeComponent(version);
    } catch (err) {
      print(err);
    }

    var package = await _resolvePackage(name, pin: _pinOf(req));
    if (package == null) {
      if (_pinOf(req) != null) return shelf.Response.notFound('Not Found');
      return shelf.Response.found(Uri.parse(upstream)
          .resolve('/api/packages/$name/versions/$version')
          .toString());
    }

    var packageVersion =
        package.versions.firstWhereOrNull((item) => item.version == version);
    if (packageVersion == null) {
      return shelf.Response.notFound('Not Found');
    }

    return _okWithJson(_versionToJson(packageVersion, req));
  }

  @Route.get('/packages/<name>/versions/<version>.tar.gz')
  Future<shelf.Response> download(
      shelf.Request req, String name, String version) async {
    // Versions like `17.2.1+1` arrive URL-encoded (`%2B`) and need to be
    // decoded before we match them against the meta store.
    try {
      version = Uri.decodeComponent(version);
    } catch (_) {
      // Leave version as-is if decoding fails — handler below will 404.
    }

    var package = await _resolvePackage(name, pin: _pinOf(req));
    if (package == null) {
      if (_pinOf(req) != null) return shelf.Response.notFound('Not Found');
      return shelf.Response.found(Uri.parse(upstream)
          .resolve('/packages/$name/versions/$version.tar.gz')
          .toString());
    }

    final hasVersion = package.versions.any((v) => v.version == version);
    if (!hasVersion && cacheUpstream && _mirrorSource(package) != null) {
      // Metadata is stale — refresh from upstream so we know the new version.
      package = await _fetchAndCacheUpstreamPackage(name,
              force: true, cached: package) ??
          package;
    }

    // Pull from upstream when the tarball isn't in our store yet — covers
    // both first-touch and the case where metadata was cached previously
    // but the tarball itself is still missing.
    final source = cacheUpstream ? _mirrorSource(package) : null;
    if (source != null) {
      try {
        final present = await packageStore.exists(name, version);
        if (present) {
          _upstreamCacheHits.inc(['tarball']);
        } else {
          await _fetchAndCacheUpstreamTarball(source, name, version);
        }
      } catch (e) {
        // Falls back to packageStore.download which will surface the real error.
        print('unpub: upstream tarball $name@$version from $source failed: $e');
      }
    }

    if (isPubClient(req)) {
      metaStore.increaseDownloads(name, version);
    }
    _downloadsTotal.inc();

    if (packageStore.supportsDownloadUrl) {
      return shelf.Response.found(
          await packageStore.downloadUrl(name, version));
    } else {
      return shelf.Response.ok(
        packageStore.download(name, version),
        headers: {HttpHeaders.contentTypeHeader: ContentType.binary.mimeType},
      );
    }
  }

  /// Uploader recorded on packages mirrored from [source].
  String _mirrorUploader(Upstream source) =>
      identical(source, _upstreams.last) && upstreamUploaderEmail != null
          ? upstreamUploaderEmail!
          : source.uploaderEmail;

  /// The upstream a cached [package] was mirrored from, or `null` when it was
  /// published to this server directly.
  Upstream? _mirrorSource(UnpubPackage package) {
    final uploaders = package.uploaders ?? const <String>[];
    return _upstreams
        .firstWhereOrNull((u) => uploaders.contains(_mirrorUploader(u)));
  }

  /// Look a package up in the local store, falling back to (and refreshing
  /// from) the upstreams when [cacheUpstream] is on.
  ///
  /// Mirrored packages are re-checked against their upstream once per
  /// [upstreamMetadataTtl] so new upstream releases become visible; if the
  /// upstream is unreachable the cached copy is served instead.
  ///
  /// With [pin], only that upstream is consulted, and a package stored from
  /// anywhere else (another upstream, or published here) is treated as absent.
  Future<UnpubPackage?> _resolvePackage(String name, {Upstream? pin}) async {
    final cached = await metaStore.queryPackage(name);
    if (pin != null && cached != null && _mirrorSource(cached) != pin) {
      return null;
    }
    if (!cacheUpstream) return cached;
    if (cached == null) {
      final fetched = await _fetchAndCacheUpstreamPackage(name, only: pin);
      return pin != null && fetched != null && _mirrorSource(fetched) != pin
          ? null
          : fetched;
    }

    final source = _mirrorSource(cached);
    final last = _lastUpstreamRefresh[name];
    if (source == null ||
        (last != null &&
            DateTime.now().difference(last) < upstreamMetadataTtl)) {
      _upstreamCacheHits.inc(['metadata']);
      return cached;
    }
    try {
      return await _fetchAndCacheUpstreamPackage(name, cached: cached) ??
          cached;
    } catch (e) {
      print('unpub: refreshing $name from $source failed, serving cache: $e');
      return cached;
    }
  }

  /// Fetch a package's metadata from upstream and persist the versions the
  /// local store is missing. Returns the cached and upstream versions merged,
  /// or `null` when no upstream has the package.
  ///
  /// With [only] set, only that upstream is asked; with [cached] set, only
  /// the upstream it was mirrored from.
  /// Otherwise [_upstreams] are tried in order and only a 404 falls through
  /// to the next one.
  ///
  /// Dedupes concurrent calls for the same package name through
  /// [_inflightMeta] so cold-cache spikes only hit upstream once.
  Future<UnpubPackage?> _fetchAndCacheUpstreamPackage(
    String name, {
    bool force = false,
    UnpubPackage? cached,
    Upstream? only,
  }) async {
    // Pinned and unpinned lookups can resolve differently; don't share them.
    final key = only == null ? name : '${only.name}:$name';
    if (!force) {
      final existing = _inflightMeta[key];
      if (existing != null) {
        _upstreamDedupHits.inc(['metadata']);
        return existing;
      }
    }
    _upstreamCacheMisses.inc(['metadata']);
    final sw = Stopwatch()..start();
    final future = _doFetchAndCacheUpstreamPackage(name, cached, only);
    _inflightMeta[key] = future;
    _inflightMetaGauge.inc();
    try {
      return await future;
    } finally {
      _inflightMeta.remove(key);
      _inflightMetaGauge.dec();
      sw.stop();
      _upstreamFetchDuration
          .observe(sw.elapsedMicroseconds / 1e6, ['metadata']);
    }
  }

  Future<UnpubPackage?> _doFetchAndCacheUpstreamPackage(
      String name, UnpubPackage? cached, Upstream? only) async {
    final pinned = only ?? (cached == null ? null : _mirrorSource(cached));
    for (final source in pinned != null ? [pinned] : _upstreams) {
      final url = source.resolve('api/packages/${Uri.encodeComponent(name)}');
      final res = await source.get(_upstreamClient, url,
          headers: {'accept': 'application/vnd.pub.v2+json'});
      if (res.statusCode == 404) continue;
      if (res.statusCode ~/ 100 != 2) {
        throw 'upstream $url returned ${res.statusCode}';
      }
      return _mergeUpstreamPackage(name, source, res.body, cached);
    }
    return null;
  }

  UnpubPackage _mergeUpstreamPackage(
      String name, Upstream source, String body, UnpubPackage? cached) {
    final versionsRaw =
        ((json.decode(body) as Map)['versions'] as List? ?? const [])
            .cast<Map<String, dynamic>>();
    final uploaderEmail = _mirrorUploader(source);
    final now = DateTime.now().toUtc();

    final upstreamVersions = <UnpubVersion>[];
    for (final v in versionsRaw) {
      final version = v['version'] as String;
      final archiveUrl = v['archive_url'] as String?;
      if (archiveUrl != null) {
        _upstreamArchiveUrls['$name@$version'] = archiveUrl;
      }
      upstreamVersions.add(UnpubVersion(
        version,
        (v['pubspec'] as Map<String, dynamic>?) ?? const <String, dynamic>{},
        v['pubspec_yaml'] as String?,
        uploaderEmail,
        null,
        null,
        now,
      ));
    }

    final queued = _persistQueued.putIfAbsent(name, () => {});
    final known = {
      for (final v in cached?.versions ?? <UnpubVersion>[]) v.version,
      ...queued,
    };
    final missing = upstreamVersions
        .where((v) => !known.contains(v.version))
        .toList()
      ..sort((a, b) => semver.Version.prioritize(
          semver.Version.parse(a.version), semver.Version.parse(b.version)));
    final merged = <String, UnpubVersion>{
      for (final v in cached?.versions ?? <UnpubVersion>[]) v.version: v,
      for (final v in upstreamVersions) v.version: v,
    }.values.toList();

    _lastUpstreamRefresh[name] = DateTime.now();
    // Persist in the background so the caller can answer right away; the
    // response is built from the merged in-memory view.
    if (missing.isNotEmpty) {
      queued.addAll(missing.map((v) => v.version));
      Future.microtask(() => _persistUpstreamVersions(name, missing));
    }
    return UnpubPackage(
      name,
      merged,
      cached?.private ?? false,
      cached?.uploaders ?? [uploaderEmail],
      cached?.createdAt ?? now,
      now,
      cached?.download ?? 0,
    );
  }

  /// Writes [versions] one at a time in ascending order, so the store's
  /// "latest version" ends up on the newest one rather than whichever
  /// concurrent write landed last.
  Future<void> _persistUpstreamVersions(
      String name, List<UnpubVersion> versions) async {
    for (final v in versions) {
      try {
        await metaStore.addVersion(name, v);
      } catch (e) {
        print('unpub: caching $name@${v.version} metadata failed: $e');
        // Let a later refresh retry it.
        _persistQueued[name]?.remove(v.version);
      }
    }
  }

  /// Pull a tarball from upstream and store it via [packageStore], unless
  /// it already exists locally. Concurrent calls for the same version are
  /// deduped through [_inflightTarballs].
  Future<List<int>> _fetchAndCacheUpstreamTarball(
      Upstream source, String name, String version) async {
    final key = '$name@$version';
    final existing = _inflightTarballs[key];
    if (existing != null) {
      _upstreamDedupHits.inc(['tarball']);
      return existing;
    }
    _upstreamCacheMisses.inc(['tarball']);
    final sw = Stopwatch()..start();
    final future = _doFetchAndCacheUpstreamTarball(source, name, version);
    _inflightTarballs[key] = future;
    _inflightTarballGauge.inc();
    try {
      return await future;
    } finally {
      _inflightTarballs.remove(key);
      _inflightTarballGauge.dec();
      sw.stop();
      _upstreamFetchDuration.observe(sw.elapsedMicroseconds / 1e6, ['tarball']);
    }
  }

  Future<List<int>> _doFetchAndCacheUpstreamTarball(
      Upstream source, String name, String version) async {
    // Prefer the archive_url upstream advertised (Cloudsmith & co. don't use
    // pub.dev's layout); fall back to the standard hosted-repository path.
    final advertised = _upstreamArchiveUrls['$name@$version'];
    final url = advertised != null
        ? Uri.parse(advertised)
        : source.resolve('packages/${Uri.encodeComponent(name)}/versions/'
            '${Uri.encodeComponent(version)}.tar.gz');
    final res = await source.get(_upstreamClient, url);
    if (res.statusCode ~/ 100 != 2) {
      throw 'upstream tarball $url returned ${res.statusCode}';
    }
    await packageStore.upload(name, version, res.bodyBytes);
    return res.bodyBytes;
  }

  @Route.get('/api/packages/versions/new')
  Future<shelf.Response> getUploadUrl(shelf.Request req) async {
    return _okWithJson({
      'url': _resolveUrl(req, '/api/packages/versions/newUpload').toString(),
      'fields': {},
    });
  }

  @Route.post('/api/packages/versions/newUpload')
  Future<shelf.Response> upload(shelf.Request req) async {
    try {
      var uploader = await _getUploaderEmail(req);

      var contentType = req.headers['content-type'];
      if (contentType == null) throw 'invalid content type';

      var mediaType = MediaType.parse(contentType);
      var boundary = mediaType.parameters['boundary'];
      if (boundary == null) throw 'invalid boundary';

      var transformer = MimeMultipartTransformer(boundary);
      MimeMultipart? fileData;

      // The map below makes the runtime type checker happy.
      // https://github.com/dart-lang/pub-dev/blob/19033f8154ca1f597ef5495acbc84a2bb368f16d/app/lib/fake/server/fake_storage_server.dart#L74
      final stream = req.read().map((a) => a).transform(transformer);
      await for (var part in stream) {
        if (fileData != null) continue;
        fileData = part;
      }

      var bb = await fileData!.fold(
          BytesBuilder(), (BytesBuilder byteBuilder, d) => byteBuilder..add(d));
      var tarballBytes = bb.takeBytes();
      var tarBytes = GZipDecoder().decodeBytes(tarballBytes);
      var archive = TarDecoder().decodeBytes(tarBytes);
      ArchiveFile? pubspecArchiveFile;
      ArchiveFile? readmeFile;
      ArchiveFile? changelogFile;

      for (var file in archive.files) {
        if (file.name == 'pubspec.yaml') {
          pubspecArchiveFile = file;
          continue;
        }
        if (file.name.toLowerCase() == 'readme.md') {
          readmeFile = file;
          continue;
        }
        if (file.name.toLowerCase() == 'changelog.md') {
          changelogFile = file;
          continue;
        }
      }

      if (pubspecArchiveFile == null) {
        throw 'Did not find any pubspec.yaml file in upload. Aborting.';
      }

      var pubspecYaml = utf8.decode(pubspecArchiveFile.content);
      var pubspec = loadYamlAsMap(pubspecYaml)!;

      if (uploadValidator != null) {
        await uploadValidator!(pubspec, uploader);
      }

      // TODO: null
      var name = pubspec['name'] as String;
      var version = pubspec['version'] as String;

      var package = await metaStore.queryPackage(name);

      // Package already exists
      if (package != null) {
        if (package.private == false) {
          throw '$name is not a private package. Please upload it to https://pub.dev';
        }

        // Skip the uploader ACL when the server is running in
        // override-uploader mode — the deployment has already decided
        // who is trusted, so per-package ACLs would just block legitimate
        // republishes from any client. Same applies when the inferred
        // uploader is empty (token-only auth path with no Google
        // tokeninfo email).
        final acl = package.uploaders ?? const [];
        if (overrideUploaderEmail == null &&
            uploader.isNotEmpty &&
            acl.isNotEmpty &&
            !acl.contains(uploader)) {
          throw '$uploader is not an uploader of $name';
        }

        // Check duplicated version
        var duplicated = package.versions
            .firstWhereOrNull((item) => version == item.version);
        if (duplicated != null) {
          throw 'version invalid: $name@$version already exists.';
        }
      }

      // Upload package tarball to storage
      await packageStore.upload(name, version, tarballBytes);
      _uploadsTotal.inc();

      String? readme;
      String? changelog;
      if (readmeFile != null) {
        readme = utf8.decode(readmeFile.content);
      }
      if (changelogFile != null) {
        changelog = utf8.decode(changelogFile.content);
      }

      // Write package meta to database
      var unpubVersion = UnpubVersion(
        version,
        pubspec,
        pubspecYaml,
        uploader,
        readme,
        changelog,
        DateTime.now(),
      );
      await metaStore.addVersion(name, unpubVersion);

      // TODO: Upload docs
      return shelf.Response.found(
          _resolveUrl(req, '/api/packages/versions/newUploadFinish'));
    } catch (err) {
      return shelf.Response.found(_resolveUrl(
          req, '/api/packages/versions/newUploadFinish?error=$err'));
    }
  }

  @Route.get('/api/packages/versions/newUploadFinish')
  Future<shelf.Response> uploadFinish(shelf.Request req) async {
    var error = req.requestedUri.queryParameters['error'];
    if (error != null) {
      return _badRequest(error);
    }
    return _successMessage('Successfully uploaded package.');
  }

  @Route.post('/api/packages/<name>/uploaders')
  Future<shelf.Response> addUploader(shelf.Request req, String name) async {
    var body = await req.readAsString();
    var email = Uri.splitQueryString(body)['email']!; // TODO: null
    var operatorEmail = await _getUploaderEmail(req);
    var package = await metaStore.queryPackage(name);

    if (package?.uploaders?.contains(operatorEmail) == false) {
      return _badRequest('no permission', status: HttpStatus.forbidden);
    }
    if (package?.uploaders?.contains(email) == true) {
      return _badRequest('email already exists');
    }

    await metaStore.addUploader(name, email);
    return _successMessage('uploader added');
  }

  @Route.delete('/api/packages/<name>/uploaders/<email>')
  Future<shelf.Response> removeUploader(
      shelf.Request req, String name, String email) async {
    email = Uri.decodeComponent(email);
    var operatorEmail = await _getUploaderEmail(req);
    var package = await metaStore.queryPackage(name);

    // TODO: null
    if (package?.uploaders?.contains(operatorEmail) == false) {
      return _badRequest('no permission', status: HttpStatus.forbidden);
    }
    if (package?.uploaders?.contains(email) == false) {
      return _badRequest('email not uploader');
    }

    await metaStore.removeUploader(name, email);
    return _successMessage('uploader removed');
  }

  @Route.get('/webapi/packages')
  Future<shelf.Response> getPackages(shelf.Request req) async {
    var params = req.requestedUri.queryParameters;
    var size = int.tryParse(params['size'] ?? '') ?? 10;
    var page = int.tryParse(params['page'] ?? '') ?? 0;
    var sort = params['sort'] ?? 'download';
    var q = params['q'];

    String? keyword;
    String? uploader;
    String? dependency;

    if (q == null) {
    } else if (q.startsWith('email:')) {
      uploader = q.substring(6).trim();
    } else if (q.startsWith('dependency:')) {
      dependency = q.substring(11).trim();
    } else {
      keyword = q;
    }

    final result = await metaStore.queryPackages(
      size: size,
      page: page,
      sort: sort,
      keyword: keyword,
      uploader: uploader,
      dependency: dependency,
    );

    var data = ListApi(result.count, [
      for (var package in result.packages)
        ListApiPackage(
          package.name,
          package.versions.last.pubspec['description'] as String?,
          getPackageTags(package.versions.last.pubspec),
          package.versions.last.version,
          package.updatedAt,
        )
    ]);

    return _okWithJson({'data': data.toJson()});
  }

  // Search upstreams for packages we haven't cached yet. Reads only — no
  // writes. Private upstreams (Cloudsmith & co.) usually have no search API,
  // so they are probed for an exact package-name match and listed first;
  // the primary upstream (pub.dev) is searched by keyword.
  @Route.get('/webapi/upstream-search')
  Future<shelf.Response> upstreamSearch(shelf.Request req) async {
    final q = (req.requestedUri.queryParameters['q'] ?? '').trim();
    if (q.isEmpty) {
      return _okWithJson({
        'data': {'packages': []}
      });
    }
    final results = await Future.wait([
      ...extraUpstreams.map((u) => _probeUpstreamName(u, q)),
      _searchPrimaryUpstream(q),
    ]);
    final seen = <String>{};
    final pkgs = [
      for (final names in results)
        for (final name in names)
          if (seen.add(name)) {'name': name}
    ];
    return _okWithJson({
      'data': {'packages': pkgs}
    });
  }

  /// `[name]` when [source] has a package named like [q], else `[]`.
  Future<List<String>> _probeUpstreamName(Upstream source, String q) async {
    final name = q.toLowerCase().replaceAll(RegExp(r'[\s-]+'), '_');
    if (!RegExp(r'^[a-z_][a-z0-9_]*$').hasMatch(name)) return const [];
    try {
      final res = await source.get(_upstreamClient,
          source.resolve('api/packages/${Uri.encodeComponent(name)}'),
          headers: {'accept': 'application/vnd.pub.v2+json'});
      return res.statusCode == 200 ? [name] : const [];
    } catch (e) {
      print('unpub: probing $source for $name failed: $e');
      return const [];
    }
  }

  Future<List<String>> _searchPrimaryUpstream(String q) async {
    try {
      final primary = _upstreams.last;
      final url =
          primary.resolve('api/search').replace(queryParameters: {'q': q});
      final res = await primary.get(_upstreamClient, url);
      if (res.statusCode != 200) return const [];
      final body = json.decode(res.body);
      final raw =
          ((body is Map ? body['packages'] : null) as List?) ?? const [];
      return raw
          .whereType<Map>()
          .map((m) => (m['package'] ?? '').toString())
          .where((name) => name.isNotEmpty)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  // Force-cache a package from upstream (used by the UI's "Pull from upstream"
  // button). Pulls metadata, persists every version, then pre-fetches the
  // latest tarball into S3 so the next `dart pub get` is a warm hit.
  @Route.post('/webapi/upstream-cache/<name>')
  Future<shelf.Response> upstreamCacheNow(
      shelf.Request req, String name) async {
    if (!cacheUpstream) {
      return _badRequest('cacheUpstream is disabled on this server');
    }
    try {
      final cached = await metaStore.queryPackage(name);
      if (cached != null && _mirrorSource(cached) == null) {
        return _badRequest('$name is published here, not mirrored');
      }
      final pkg = await _fetchAndCacheUpstreamPackage(name,
          force: true, cached: cached);
      final source = pkg == null ? null : _mirrorSource(pkg);
      if (pkg == null || source == null) {
        return _badRequest('upstream did not return $name',
            status: HttpStatus.notFound);
      }
      String? latest;
      if (pkg.versions.isNotEmpty) {
        latest = pkg.versions
            .map((v) => semver.Version.parse(v.version))
            .reduce((a, b) => semver.Version.prioritize(a, b) >= 0 ? a : b)
            .toString();
        try {
          if (!await packageStore.exists(name, latest)) {
            await _fetchAndCacheUpstreamTarball(source, name, latest);
          }
        } catch (e) {
          // Best-effort; the on-demand download path will retry.
          print('unpub: pre-fetching $name@$latest failed: $e');
        }
      }
      return _okWithJson({
        'data': {
          'name': name,
          'versions': pkg.versions.length,
          'latest': latest,
        }
      });
    } catch (e) {
      return _badRequest('failed to cache $name: $e',
          status: HttpStatus.badGateway);
    }
  }

  @Route.get('/packages/<name>.json')
  Future<shelf.Response> getPackageVersions(
      shelf.Request req, String name) async {
    var package = await metaStore.queryPackage(name);
    if (package == null) {
      return _badRequest('package not exists', status: HttpStatus.notFound);
    }

    var versions = package.versions.map((v) => v.version).toList();
    versions.sort((a, b) {
      return semver.Version.prioritize(
          semver.Version.parse(b), semver.Version.parse(a));
    });

    return _okWithJson({
      'name': name,
      'versions': versions,
    });
  }

  @Route.get('/webapi/package/<name>/<version>')
  Future<shelf.Response> getPackageDetail(
      shelf.Request req, String name, String version) async {
    // `dart pub` URL-encodes `+` in versions (`17.2.1+1` -> `17.2.1%2B1`);
    // shelf_router decodes once, but be defensive in case a client double-
    // encodes.
    try {
      version = Uri.decodeComponent(version);
    } catch (_) {/* leave as-is */}

    var package = await _resolvePackage(name, pin: _pinOf(req));
    if (package == null) {
      return _okWithJson({'error': 'package not exists'});
    }

    UnpubVersion? packageVersion;
    if (version == 'latest') {
      packageVersion = package.versions.last;
    } else {
      packageVersion =
          package.versions.firstWhereOrNull((item) => item.version == version);
      // Metadata may be stale (we cached an older snapshot); refresh once.
      if (packageVersion == null &&
          cacheUpstream &&
          _mirrorSource(package) != null) {
        package = await _fetchAndCacheUpstreamPackage(name,
            force: true, cached: package);
        if (package != null) {
          packageVersion = package.versions
              .firstWhereOrNull((item) => item.version == version);
        }
      }
    }
    if (packageVersion == null || package == null) {
      return _okWithJson({'error': 'version not exists'});
    }
    final pkg = package;

    var versions = pkg.versions
        .map((v) => DetailViewVersion(v.version, v.createdAt))
        .toList();
    versions.sort((a, b) {
      return semver.Version.prioritize(
          semver.Version.parse(b.version), semver.Version.parse(a.version));
    });

    var pubspec = packageVersion.pubspec;
    List<String?> authors;
    if (pubspec['author'] != null) {
      authors = RegExp(r'<(.*?)>')
          .allMatches(pubspec['author'])
          .map((match) => match.group(1))
          .toList();
    } else if (pubspec['authors'] != null) {
      authors = (pubspec['authors'] as List)
          .map((author) => RegExp(r'<(.*?)>').firstMatch(author)!.group(1))
          .toList();
    } else {
      authors = [];
    }

    var depMap = (pubspec['dependencies'] as Map? ?? {}).cast<String, String>();

    var data = WebapiDetailView(
      pkg.name,
      packageVersion.version,
      packageVersion.pubspec['description'] ?? '',
      packageVersion.pubspec['homepage'] ?? '',
      pkg.uploaders ?? [],
      packageVersion.createdAt,
      packageVersion.readme,
      packageVersion.changelog,
      versions,
      authors,
      depMap.keys.toList(),
      getPackageTags(packageVersion.pubspec),
    );

    return _okWithJson({'data': data.toJson()});
  }

  @Route.get('/')
  @Route.get('/packages')
  @Route.get('/packages/<name>')
  @Route.get('/packages/<name>/versions/<version>')
  Future<shelf.Response> indexHtml(shelf.Request req) async {
    return shelf.Response.ok(index_html.content,
        headers: {HttpHeaders.contentTypeHeader: ContentType.html.mimeType});
  }

  // /documentation/<name>/<version>/ and any other read-only pub.dev page
  // that we don't render locally — redirect to the upstream so the user
  // sees something useful instead of 404.
  @Route.get('/documentation/<path|.*>')
  Future<shelf.Response> documentation(shelf.Request req, String path) async {
    return shelf.Response.found(
        Uri.parse(upstream).resolve('/documentation/$path').toString());
  }

  // pub.dev exposes tarballs at /api/archives/<name>-<version>.tar.gz.
  // Pub clients that have cached an old `archive_url` may still hit this
  // form. Redirect to our canonical /packages/<name>/versions/<v>.tar.gz.
  @Route.get('/api/archives/<archive>')
  Future<shelf.Response> archives(shelf.Request req, String archive) async {
    final stripped = archive.endsWith('.tar.gz')
        ? archive.substring(0, archive.length - '.tar.gz'.length)
        : archive;
    final dash = stripped.indexOf('-');
    if (dash < 0) {
      return shelf.Response.notFound('Not Found');
    }
    final name = stripped.substring(0, dash);
    final version = stripped.substring(dash + 1);
    return shelf.Response.found(_resolveUrl(req,
            '/packages/$name/versions/${Uri.encodeComponent(version)}.tar.gz')
        .toString());
  }

  @Route.get('/main.dart.js')
  Future<shelf.Response> mainDartJs(shelf.Request req) async {
    return shelf.Response.ok(main_dart_js.content,
        headers: {HttpHeaders.contentTypeHeader: 'text/javascript'});
  }

  String _getBadgeUrl(String label, String message, String color,
      Map<String, String> queryParameters) {
    var badgeUri = Uri.parse('https://img.shields.io/static/v1');
    return Uri(
        scheme: badgeUri.scheme,
        host: badgeUri.host,
        path: badgeUri.path,
        queryParameters: {
          'label': label,
          'message': message,
          'color': color,
          ...queryParameters,
        }).toString();
  }

  @Route.get('/badge/<type>/<name>')
  Future<shelf.Response> badge(
      shelf.Request req, String type, String name) async {
    var queryParameters = req.requestedUri.queryParameters;
    var package = await metaStore.queryPackage(name);
    if (package == null) {
      return shelf.Response.notFound('Not found');
    }

    switch (type) {
      case 'v':
        var latest = semver.Version.primary(package.versions
            .map((pv) => semver.Version.parse(pv.version))
            .toList());

        var color = latest.major == 0 ? 'orange' : 'blue';

        return shelf.Response.found(
            _getBadgeUrl('unpub', latest.toString(), color, queryParameters));
      case 'd':
        return shelf.Response.found(_getBadgeUrl(
            'downloads', package.download.toString(), 'blue', queryParameters));
      default:
        return shelf.Response.notFound('Not found');
    }
  }
}
