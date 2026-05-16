import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:unpub/unpub.dart';

import '../dynamodb/dynamo_meta_store.dart' show DailyDownloadStats;
import 's3_client.dart';

/// Iceberg-inspired metadata store backed by S3.
///
/// Layout:
///   meta/packages/<name>/current.json         -> pointer { snapshot, seq }
///   meta/packages/<name>/snap-<seq>-<uuid>.json -> immutable snapshot of UnpubPackage
///   meta/packages/<name>/versions/<semver>.json -> immutable per-version metadata
///   meta/catalog/index.json                    -> { packages: [{name, seq, updatedAt, latestVersion, download}] }
///   meta/downloads/<yyyy-mm-dd>/<name>-<uuid>.json -> append-only download events
///
/// Concurrency: writes use `If-None-Match: *` for immutable objects and
/// `If-Match: <etag>` for the mutable pointers (current.json and catalog/index.json).
/// On conflict we reload and retry up to [maxRetries] times.
class S3MetaStore extends MetaStore {
  final S3Client client;
  final String prefix;
  final int maxRetries;
  final Random _rand = Random.secure();

  S3MetaStore(this.client, {this.prefix = 'meta', this.maxRetries = 5});

  // ---------------------------------------------------------------------------
  // Public MetaStore API
  // ---------------------------------------------------------------------------

  @override
  Future<UnpubPackage?> queryPackage(String name) async {
    final pointer = await _readPointer(name);
    if (pointer == null) return null;
    final snap = await client.getObject('$prefix/packages/$name/${pointer.snapshot}');
    if (!snap.exists) return null;
    return UnpubPackage.fromJson(_restorePackageJson(
        json.decode(snap.bodyAsString()!) as Map<String, dynamic>));
  }

  @override
  Future<void> addVersion(String name, UnpubVersion version) async {
    // Write per-version file (idempotent).
    final versionKey =
        '$prefix/packages/$name/versions/${version.version}.json';
    try {
      await client.putObject(
        versionKey,
        utf8.encode(json.encode(_normalizeJson(version.toJson()))),
        contentType: 'application/json',
        ifNoneMatch: '*',
      );
    } on S3PreconditionFailed {
      // Already present — that's fine for idempotent retries.
    }

    await _commit(name, (pkg) {
      final existing = pkg ??
          UnpubPackage(
            name,
            <UnpubVersion>[],
            true,
            version.uploader == null ? <String>[] : [version.uploader!],
            version.createdAt,
            version.createdAt,
            0,
          );

      if (existing.versions.any((v) => v.version == version.version)) {
        return existing; // no-op; commit will be a no-op write below
      }

      final newVersions = [...existing.versions, version];
      final uploaders = {...?existing.uploaders};
      if (version.uploader != null) uploaders.add(version.uploader!);

      return UnpubPackage(
        existing.name,
        newVersions,
        existing.private,
        uploaders.toList(),
        existing.createdAt,
        version.createdAt,
        existing.download ?? 0,
      );
    });
  }

  @override
  Future<void> addUploader(String name, String email) async {
    await _commit(name, (pkg) {
      if (pkg == null) {
        throw StateError('Cannot addUploader: package $name does not exist');
      }
      final uploaders = {...?pkg.uploaders, email}.toList();
      return UnpubPackage(
        pkg.name,
        pkg.versions,
        pkg.private,
        uploaders,
        pkg.createdAt,
        DateTime.now().toUtc(),
        pkg.download ?? 0,
      );
    });
  }

  @override
  Future<void> removeUploader(String name, String email) async {
    await _commit(name, (pkg) {
      if (pkg == null) {
        throw StateError('Cannot removeUploader: package $name does not exist');
      }
      final uploaders =
          (pkg.uploaders ?? const <String>[]).where((u) => u != email).toList();
      return UnpubPackage(
        pkg.name,
        pkg.versions,
        pkg.private,
        uploaders,
        pkg.createdAt,
        DateTime.now().toUtc(),
        pkg.download ?? 0,
      );
    });
  }

  @override
  void increaseDownloads(String name, String version) {
    // Fire-and-forget append-only event. Aggregated out-of-band.
    final ts = DateTime.now().toUtc();
    final date = _isoDate(ts);
    final key = '$prefix/downloads/$date/$name-${_randomId()}.json';
    final body = utf8.encode(json.encode({
      'name': name,
      'version': version,
      'ts': ts.toIso8601String(),
    }));
    client
        .putObject(key, body,
            contentType: 'application/json', ifNoneMatch: '*')
        .catchError((_) => '');
  }

  /// Aggregate raw download events for a given package + date by listing
  /// `meta/downloads/<date>/<name>-*.json` and counting hits. O(N) reads
  /// — meant for ad-hoc queries or a periodic compactor that writes the
  /// rolled-up counts to `meta/stats/<name>/<date>.json`.
  Future<DailyDownloadStats> aggregateDailyDownloads(
      String name, DateTime date) async {
    final iso = _isoDate(date);
    final prefixPath = '$prefix/downloads/$iso/$name-';
    final perVersion = <String, int>{};
    var total = 0;
    String? token;
    do {
      final res = await client.listObjects(
        prefix: prefixPath,
        continuationToken: token,
      );
      for (final entry in res.contents) {
        final body = await client.getObject(entry.key);
        if (!body.exists) continue;
        final ev =
            json.decode(body.bodyAsString()!) as Map<String, dynamic>;
        final v = (ev['version'] as String?) ?? 'unknown';
        perVersion[v] = (perVersion[v] ?? 0) + 1;
        total++;
      }
      token = res.nextContinuationToken;
    } while (token != null);
    return DailyDownloadStats(
      name: name,
      date: iso,
      total: total,
      perVersion: perVersion,
    );
  }

  /// Persist a rolled-up daily count under `meta/stats/<name>/<yyyy-mm-dd>.json`.
  /// Idempotent: overwrites any prior aggregate for the same date.
  Future<void> persistDailyStats(DailyDownloadStats stats) async {
    final key = '$prefix/stats/${stats.name}/${stats.date}.json';
    await client.putObject(
      key,
      utf8.encode(json.encode(stats.toJson())),
      contentType: 'application/json',
    );
  }

  /// Read a persisted daily rollup. Returns null if no rollup yet for date.
  Future<DailyDownloadStats?> readDailyStats(String name, DateTime date) async {
    final iso = _isoDate(date);
    final res = await client.getObject('$prefix/stats/$name/$iso.json');
    if (!res.exists) return null;
    final m = json.decode(res.bodyAsString()!) as Map<String, dynamic>;
    return DailyDownloadStats(
      name: m['name'] as String,
      date: m['date'] as String,
      total: (m['total'] as int?) ?? 0,
      perVersion:
          ((m['perVersion'] as Map?) ?? const {}).cast<String, int>(),
    );
  }

  String _isoDate(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  @override
  Future<UnpubQueryResult> queryPackages({
    required int size,
    required int page,
    required String sort,
    String? keyword,
    String? uploader,
    String? dependency,
  }) async {
    final index = await _readCatalogIndex();
    var entries = index.entries;

    if (keyword != null && keyword.isNotEmpty) {
      final lower = keyword.toLowerCase();
      entries = entries.where((e) => e.name.toLowerCase().contains(lower)).toList();
    }

    // Sort
    entries.sort((a, b) {
      switch (sort) {
        case 'download':
          return b.download.compareTo(a.download);
        case 'name':
          return a.name.compareTo(b.name);
        case 'createdAt':
        case 'updatedAt':
        default:
          return b.updatedAt.compareTo(a.updatedAt);
      }
    });

    final total = entries.length;
    final start = page * size;
    final end = (start + size).clamp(0, total);
    final pageEntries =
        start >= total ? <_CatalogEntry>[] : entries.sublist(start, end);

    final packages = <UnpubPackage>[];
    for (final entry in pageEntries) {
      final pkg = await queryPackage(entry.name);
      if (pkg == null) continue;
      if (uploader != null &&
          !(pkg.uploaders ?? const []).contains(uploader)) {
        continue;
      }
      if (dependency != null) {
        final hasDep = pkg.versions.any((v) {
          final deps = (v.pubspec['dependencies'] as Map?) ?? const {};
          return deps.containsKey(dependency);
        });
        if (!hasDep) continue;
      }
      packages.add(pkg);
    }

    return UnpubQueryResult(total, packages);
  }

  // ---------------------------------------------------------------------------
  // Internal helpers
  // ---------------------------------------------------------------------------

  Future<void> _commit(
      String name, UnpubPackage Function(UnpubPackage? existing) mutate) async {
    for (var attempt = 0; attempt < maxRetries; attempt++) {
      final pointer = await _readPointer(name);
      UnpubPackage? existing;
      if (pointer != null) {
        final snap =
            await client.getObject('$prefix/packages/$name/${pointer.snapshot}');
        if (snap.exists) {
          existing = UnpubPackage.fromJson(_restorePackageJson(
              json.decode(snap.bodyAsString()!) as Map<String, dynamic>));
        }
      }

      final next = mutate(existing);

      // Write new immutable snapshot.
      final newSeq = (pointer?.seq ?? 0) + 1;
      final snapId = 'snap-${newSeq.toString().padLeft(8, '0')}-${_randomId()}.json';
      final snapKey = '$prefix/packages/$name/$snapId';
      await client.putObject(
        snapKey,
        utf8.encode(json.encode(_packageToJson(next))),
        contentType: 'application/json',
        ifNoneMatch: '*',
      );

      // CAS-swap the pointer.
      final pointerKey = '$prefix/packages/$name/current.json';
      final pointerBody = utf8.encode(json.encode({
        'snapshot': snapId,
        'seq': newSeq,
      }));

      try {
        if (pointer == null) {
          await client.putObject(
            pointerKey,
            pointerBody,
            contentType: 'application/json',
            ifNoneMatch: '*',
          );
        } else {
          await client.putObject(
            pointerKey,
            pointerBody,
            contentType: 'application/json',
            ifMatch: pointer.etag,
          );
        }
      } on S3PreconditionFailed {
        // Someone committed concurrently. Discard our snapshot, retry.
        await client.deleteObject(snapKey);
        await Future.delayed(_backoff(attempt));
        continue;
      }

      await _upsertCatalogIndex(_CatalogEntry(
        name: next.name,
        seq: newSeq,
        updatedAt: next.updatedAt,
        latestVersion: _latestVersion(next),
        download: next.download ?? 0,
      ));

      return;
    }

    throw StateError('S3MetaStore commit failed after $maxRetries retries: $name');
  }

  Future<_Pointer?> _readPointer(String name) async {
    final res =
        await client.getObject('$prefix/packages/$name/current.json');
    if (!res.exists) return null;
    final body = json.decode(res.bodyAsString()!) as Map<String, dynamic>;
    return _Pointer(
      snapshot: body['snapshot'] as String,
      seq: body['seq'] as int,
      etag: res.etag,
    );
  }

  Future<_CatalogIndex> _readCatalogIndex() async {
    final res = await client.getObject('$prefix/catalog/index.json');
    if (!res.exists) return _CatalogIndex(entries: [], etag: null);
    final body = json.decode(res.bodyAsString()!) as Map<String, dynamic>;
    final list = (body['packages'] as List? ?? const [])
        .cast<Map<String, dynamic>>()
        .map(_CatalogEntry.fromJson)
        .toList();
    return _CatalogIndex(entries: list, etag: res.etag);
  }

  Future<void> _upsertCatalogIndex(_CatalogEntry entry) async {
    for (var attempt = 0; attempt < maxRetries; attempt++) {
      final index = await _readCatalogIndex();
      final newEntries = index.entries
          .where((e) => e.name != entry.name)
          .toList()
        ..add(entry);
      final body = utf8.encode(json.encode({
        'packages': newEntries.map((e) => e.toJson()).toList(),
      }));
      try {
        await client.putObject(
          '$prefix/catalog/index.json',
          body,
          contentType: 'application/json',
          ifMatch: index.etag,
          ifNoneMatch: index.etag == null ? '*' : null,
        );
        return;
      } on S3PreconditionFailed {
        await Future.delayed(_backoff(attempt));
      }
    }
    // Best-effort: catalog can be reconciled by a periodic job if it drifts.
  }

  Map<String, dynamic> _packageToJson(UnpubPackage p) => {
        'name': p.name,
        'versions': p.versions.map((v) => _normalizeJson(v.toJson())).toList(),
        'private': p.private,
        'uploaders': p.uploaders,
        'createdAt': p.createdAt.toIso8601String(),
        'updatedAt': p.updatedAt.toIso8601String(),
        'download': p.download ?? 0,
      };

  /// Recursively turn DateTime values into ISO-8601 strings so `json.encode`
  /// accepts the payload. UnpubVersion.toJson() leaves DateTimes raw because
  /// the upstream models use identity fromJson/toJson converters.
  dynamic _normalizeJson(dynamic value) {
    if (value is DateTime) return value.toUtc().toIso8601String();
    if (value is Map) {
      return value.map((k, v) => MapEntry(k, _normalizeJson(v)));
    }
    if (value is List) return value.map(_normalizeJson).toList();
    return value;
  }

  /// Inverse of [_normalizeJson] — convert known timestamp fields back to
  /// DateTime so `UnpubVersion.fromJson` (identity caster) doesn't fail.
  Map<String, dynamic> _restorePackageJson(Map<String, dynamic> raw) {
    final restored = <String, dynamic>{...raw};
    if (restored['createdAt'] is String) {
      restored['createdAt'] = DateTime.parse(restored['createdAt'] as String);
    }
    if (restored['updatedAt'] is String) {
      restored['updatedAt'] = DateTime.parse(restored['updatedAt'] as String);
    }
    if (restored['versions'] is List) {
      restored['versions'] = (restored['versions'] as List).map((v) {
        if (v is Map<String, dynamic>) {
          final m = <String, dynamic>{...v};
          if (m['createdAt'] is String) {
            m['createdAt'] = DateTime.parse(m['createdAt'] as String);
          }
          return m;
        }
        return v;
      }).toList();
    }
    return restored;
  }

  String _latestVersion(UnpubPackage p) =>
      p.versions.isEmpty ? '' : p.versions.last.version;

  String _randomId() {
    final bytes = List<int>.generate(8, (_) => _rand.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  Duration _backoff(int attempt) {
    final base = 50 * (1 << attempt);
    final jitter = _rand.nextInt(50);
    return Duration(milliseconds: base + jitter);
  }
}

class _Pointer {
  final String snapshot;
  final int seq;
  final String? etag;
  _Pointer({required this.snapshot, required this.seq, this.etag});
}

class _CatalogIndex {
  final List<_CatalogEntry> entries;
  final String? etag;
  _CatalogIndex({required this.entries, this.etag});
}

class _CatalogEntry {
  final String name;
  final int seq;
  final DateTime updatedAt;
  final String latestVersion;
  final int download;

  _CatalogEntry({
    required this.name,
    required this.seq,
    required this.updatedAt,
    required this.latestVersion,
    required this.download,
  });

  factory _CatalogEntry.fromJson(Map<String, dynamic> m) => _CatalogEntry(
        name: m['name'] as String,
        seq: m['seq'] as int,
        updatedAt: DateTime.parse(m['updatedAt'] as String),
        latestVersion: (m['latestVersion'] as String?) ?? '',
        download: (m['download'] as int?) ?? 0,
      );

  Map<String, dynamic> toJson() => {
        'name': name,
        'seq': seq,
        'updatedAt': updatedAt.toIso8601String(),
        'latestVersion': latestVersion,
        'download': download,
      };
}
