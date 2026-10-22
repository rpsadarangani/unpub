import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:test/test.dart';
import 'package:unpub/unpub.dart';

class MemoryMetaStore extends MetaStore {
  final Map<String, UnpubPackage> packages = {};
  final List<String> added = [];

  @override
  Future<UnpubPackage?> queryPackage(String name) async => packages[name];

  @override
  Future<void> addVersion(String name, UnpubVersion version) async {
    added.add('$name@${version.version}');
    final p = packages[name];
    final now = DateTime.now();
    packages[name] = UnpubPackage(name, [...?p?.versions, version], false,
        p?.uploaders ?? [version.uploader!], now, now, 0);
  }

  @override
  Future<void> addUploader(String name, String email) async {}
  @override
  Future<void> removeUploader(String name, String email) async {}
  @override
  void increaseDownloads(String name, String version) {}
  @override
  Future<UnpubQueryResult> queryPackages(
          {required int size,
          required int page,
          required String sort,
          String? keyword,
          String? uploader,
          String? dependency}) async =>
      UnpubQueryResult(0, []);
}

class MemoryPackageStore extends PackageStore {
  final Map<String, List<int>> blobs = {};

  @override
  Future<void> upload(String name, String version, List<int> content) async {
    blobs['$name@$version'] = content;
  }

  @override
  Stream<List<int>> download(String name, String version) =>
      Stream.value(blobs['$name@$version']!);

  @override
  Future<bool> exists(String name, String version) async =>
      blobs.containsKey('$name@$version');
}

UnpubVersion v(String version, String uploader) => UnpubVersion(
    version, {'name': 'x'}, null, uploader, null, null, DateTime.now());

String meta(String base, String name, List<String> versions) => json.encode({
      'name': name,
      'versions': [
        for (final ver in versions)
          {
            'version': ver,
            'pubspec': {'name': name, 'version': ver},
            'archive_url': '$base/packages/$name/versions/$ver',
          }
      ],
    });

shelf.Request get(String path) =>
    shelf.Request('GET', Uri.parse('http://unpub.test$path'));

Future<List<String>> versionsOf(shelf.Response res) async {
  final body = json.decode(await res.readAsString()) as Map;
  return [for (final v in body['versions'] as List) v['version'] as String];
}

void main() {
  const cs = 'https://dart.cloudsmith.io/org/repo';
  late MemoryMetaStore metaStore;
  late MemoryPackageStore packageStore;
  late List<http.Request> calls;

  App app(Future<http.Response> Function(http.Request) handler,
          {Duration ttl = const Duration(minutes: 10)}) =>
      App(
        metaStore: metaStore,
        packageStore: packageStore,
        cacheUpstream: true,
        upstreamMetadataTtl: ttl,
        extraUpstreams: [Upstream(cs, name: 'cloudsmith', token: 's3cret')],
        upstreamClient: MockClient((req) {
          calls.add(req);
          return handler(req);
        }),
      );

  setUp(() {
    metaStore = MemoryMetaStore();
    packageStore = MemoryPackageStore();
    calls = [];
  });

  test('private upstream keeps its path prefix and gets the token', () async {
    final a = app((req) async => req.url.toString() == '$cs/api/packages/oa_sdk'
        ? http.Response(meta(cs, 'oa_sdk', ['1.0.0']), 200)
        : http.Response('', 404));

    final res = await a.getVersions(get('/api/packages/oa_sdk'), 'oa_sdk');

    expect(res.statusCode, 200);
    expect(await versionsOf(res), ['1.0.0']);
    expect(calls.single.headers['authorization'], 'Bearer s3cret');
  });

  test('only a 404 from the private upstream falls through to pub.dev',
      () async {
    final a = app((req) async {
      if (req.url.host == 'pub.dev') {
        return http.Response(meta('https://pub.dev', 'path', ['1.9.1']), 200);
      }
      return http.Response('', 404);
    });
    final res = await a.getVersions(get('/api/packages/path'), 'path');
    expect(await versionsOf(res), ['1.9.1']);
    expect(calls.map((c) => c.url.host), ['dart.cloudsmith.io', 'pub.dev']);
    expect(calls.last.headers.containsKey('authorization'), isFalse);

    calls.clear();
    final b = app((req) async => http.Response('boom', 503));
    await expectLater(
        b.getVersions(get('/api/packages/other'), 'other'), throwsA(anything));
    expect(calls.map((c) => c.url.host), ['dart.cloudsmith.io']);
  });

  test('stale mirrored metadata is refreshed and only new versions stored',
      () async {
    metaStore.packages['path'] = UnpubPackage(
        'path',
        [v('1.0.0', 'upstream@pub.dev'), v('1.0.0', 'upstream@pub.dev')],
        false,
        ['upstream@pub.dev'],
        DateTime.now(),
        DateTime.now(),
        0);
    final a = app((req) async => http.Response(
        meta('https://pub.dev', 'path', ['1.0.0', '1.2.0', '1.1.0']), 200));

    final res = await a.getVersions(get('/api/packages/path'), 'path');
    expect(await versionsOf(res), ['1.0.0', '1.1.0', '1.2.0']);
    expect(calls.single.url.host, 'pub.dev');
    await Future.delayed(Duration.zero);
    expect(metaStore.added, ['path@1.1.0', 'path@1.2.0']);

    // Within the TTL the cache is served without asking upstream again.
    calls.clear();
    await a.getVersions(get('/api/packages/path'), 'path');
    expect(calls, isEmpty);
  });

  test('a refresh racing an unfinished persist does not duplicate versions',
      () async {
    final a = app((req) async => http.Response(
        meta('https://pub.dev', 'path', ['1.0.0', '1.1.0']), 200));
    await a.getVersions(get('/api/packages/path'), 'path');
    // Second (forced) refresh before the background persist has run.
    await a.download(
        get('/packages/path/versions/9.9.9.tar.gz'), 'path', '9.9.9');
    await Future.delayed(Duration.zero);
    await Future.delayed(Duration.zero);
    expect(metaStore.added, ['path@1.0.0', 'path@1.1.0']);
  });

  test('locally published packages are never refreshed from upstream',
      () async {
    metaStore.packages['core'] = UnpubPackage('core', [v('1.0.0', 'me@corp')],
        true, ['me@corp'], DateTime.now(), DateTime.now(), 0);
    final a = app((req) async => http.Response('', 500));
    final res = await a.getVersions(get('/api/packages/core'), 'core');
    expect(await versionsOf(res), ['1.0.0']);
    expect(calls, isEmpty);
  });

  test('tarball uses archive_url and drops auth on cross-host redirect',
      () async {
    final a = app((req) async {
      final url = req.url.toString();
      if (url == '$cs/api/packages/oa_sdk') {
        return http.Response(meta(cs, 'oa_sdk', ['1.0.0']), 200);
      }
      if (url == '$cs/packages/oa_sdk/versions/1.0.0') {
        return http.Response('', 302,
            headers: {'location': 'https://dl.cloudsmith.io/signed/x.tgz'});
      }
      if (url == 'https://dl.cloudsmith.io/signed/x.tgz') {
        return http.Response.bytes([1, 2, 3], 200);
      }
      return http.Response('', 404);
    });

    final res = await a.download(
        get('/packages/oa_sdk/versions/1.0.0.tar.gz'), 'oa_sdk', '1.0.0');
    expect(res.statusCode, 200);
    expect(packageStore.blobs['oa_sdk@1.0.0'], [1, 2, 3]);
    final auth = {
      for (final c in calls) c.url.host: c.headers['authorization']
    };
    expect(auth['dart.cloudsmith.io'], 'Bearer s3cret');
    expect(auth['dl.cloudsmith.io'], isNull);
  });

  test('upstream reachable errors fall back to the cached copy', () async {
    metaStore.packages['path'] = UnpubPackage(
        'path',
        [v('1.0.0', 'upstream@pub.dev')],
        false,
        ['upstream@pub.dev'],
        DateTime.now(),
        DateTime.now(),
        0);
    final a = app((req) async => http.Response('down', 502));
    final res = await a.getVersions(get('/api/packages/path'), 'path');
    expect(await versionsOf(res), ['1.0.0']);
  });

  test('basic auth header', () async {
    final u = Upstream('https://repo.example/dart',
        name: 'repo', username: 'u', password: 'p');
    final client = MockClient((req) async {
      calls.add(req);
      return http.Response('{}', 200);
    });
    await u.get(client, u.resolve('api/packages/x'));
    expect(calls.single.url.toString(),
        'https://repo.example/dart/api/packages/x');
    expect(calls.single.headers['authorization'],
        'Basic ${base64.encode(utf8.encode('u:p'))}');
    expect(u.uploaderEmail, 'upstream@repo.example/dart');
  });

  Future<List<String>> searchNames(App a, String q) async {
    final res = await a.upstreamSearch(
        get('/webapi/upstream-search?q=${Uri.encodeQueryComponent(q)}'));
    final body = json.decode(await res.readAsString()) as Map;
    return [
      for (final p in body['data']['packages'] as List) p['name'] as String
    ];
  }

  test('upstream search lists exact-name hits from private upstreams first',
      () async {
    final a = app((req) async {
      final url = req.url.toString();
      if (url == '$cs/api/packages/oa_flights_sdk') {
        return http.Response(meta(cs, 'oa_flights_sdk', ['1.0.0']), 200);
      }
      if (req.url.host == 'pub.dev' && req.url.path == '/api/search') {
        return http.Response(
            json.encode({
              'packages': [
                {'package': 'oa_flights_sdk'},
                {'package': 'flights'},
              ]
            }),
            200);
      }
      return http.Response('', 404);
    });

    expect(await searchNames(a, ' OA-Flights SDK '), [
      'oa_flights_sdk',
      'flights',
    ]);
    final probe = calls.firstWhere((c) => c.url.host == 'dart.cloudsmith.io');
    expect(probe.headers['authorization'], 'Bearer s3cret');
  });

  test('upstream search skips the name probe for non-package queries',
      () async {
    final a = app((req) async => req.url.host == 'pub.dev'
        ? http.Response(json.encode({'packages': []}), 200)
        : http.Response('', 404));
    expect(await searchNames(a, 'flight search!'), isEmpty);
    expect(calls.map((c) => c.url.host), ['pub.dev']);
  });

  group('pinned /u/<name>/ URLs', () {
    Future<shelf.Response> send(App a, String path,
            {String method = 'GET'}) async =>
        await a.handler(
            shelf.Request(method, Uri.parse('http://unpub.test$path')));

    Future<http.Response> both(http.Request req) async {
      final url = req.url.toString();
      if (url == '$cs/api/packages/oa_sdk') {
        return http.Response(meta(cs, 'oa_sdk', ['1.0.0']), 200);
      }
      if (url == '$cs/packages/oa_sdk/versions/1.0.0') {
        return http.Response.bytes([7, 7], 200);
      }
      if (url == 'https://pub.dev/api/packages/path') {
        return http.Response(meta('https://pub.dev', 'path', ['1.9.1']), 200);
      }
      return http.Response('', 404);
    }

    test('only the named upstream is asked; archive_url keeps the pin',
        () async {
      final a = app(both);
      final res = await send(a, '/u/cloudsmith/api/packages/oa_sdk');
      expect(res.statusCode, 200);
      final body = json.decode(await res.readAsString()) as Map;
      expect(body['latest']['archive_url'],
          'http://unpub.test/u/cloudsmith/packages/oa_sdk/versions/1.0.0.tar.gz');
      expect(calls.map((c) => c.url.host), ['dart.cloudsmith.io']);

      final tar =
          await send(a, '/u/cloudsmith/packages/oa_sdk/versions/1.0.0.tar.gz');
      expect(tar.statusCode, 200);
      expect(packageStore.blobs['oa_sdk@1.0.0'], [7, 7]);
    });

    test('pinning the primary upstream skips the private ones', () async {
      final a = app(both);
      final res = await send(a, '/u/pub/api/packages/path');
      expect(await versionsOf(res), ['1.9.1']);
      expect(calls.map((c) => c.url.host), ['pub.dev']);
    });

    test('a miss on the pinned upstream is a 404, never pub.dev', () async {
      final a = app(both);
      final res = await send(a, '/u/cloudsmith/api/packages/path');
      expect(res.statusCode, 404);
      expect(calls.map((c) => c.url.host), ['dart.cloudsmith.io']);
    });

    test('a package cached from another upstream is not served', () async {
      final a = app(both);
      await send(a, '/api/packages/path'); // mirrored from pub.dev
      await Future.delayed(Duration.zero);
      calls.clear();
      final res = await send(a, '/u/cloudsmith/api/packages/path');
      expect(res.statusCode, 404);
      expect(calls, isEmpty);
    });

    test('unknown upstreams and non-read routes are 404', () async {
      final a = app(both);
      expect((await send(a, '/u/nope/api/packages/oa_sdk')).statusCode, 404);
      expect(
          (await send(a, '/u/cloudsmith/api/packages/versions/new')).statusCode,
          404);
      expect(
          (await send(a, '/u/cloudsmith/api/packages/versions/newUpload',
                  method: 'POST'))
              .statusCode,
          404);
      expect(calls, isEmpty);
    });

    test('metric route labels stay bounded', () async {
      final a = app(both);
      await send(a, '/u/cloudsmith/api/packages/oa_sdk');
      await send(a, '/u/nope/api/packages/x');
      final metrics = a.metrics.render();
      expect(metrics,
          contains('route="/u/cloudsmith/api/packages/<name>",method="GET"'));
      expect(metrics, contains('route="/u/<unknown>/api/packages/<name>"'));
      expect(metrics, isNot(contains('oa_sdk')));
    });

    test('upstream names must be unique and URL-safe', () {
      expect(() => Upstream(cs, name: 'Cloud Smith'), throwsArgumentError);
      expect(
          () => App(
                metaStore: metaStore,
                packageStore: packageStore,
                extraUpstreams: [Upstream(cs, name: 'pub')],
              ),
          throwsArgumentError);
    });
  });
}
