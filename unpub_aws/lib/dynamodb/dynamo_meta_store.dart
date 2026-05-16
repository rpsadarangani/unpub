import 'dart:async';
import 'dart:convert';

import 'package:unpub/unpub.dart';

import 'dynamo_client.dart';

/// MetaStore backed by DynamoDB.
///
/// Table schema (single-table):
///   PK: name (String)
///
/// Stored attributes:
///   name           (S)  package name
///   versions       (L of M) ordered list of UnpubVersion JSON
///   uploaders      (SS) set of uploader emails
///   private        (BOOL)
///   createdAt      (S)  ISO-8601
///   updatedAt      (S)  ISO-8601
///   download       (N)  monotonically increasing counter
///   latestVersion  (S)  for cheap listing
///   _all           (S)  constant "1" — partition key for GSI listing
///
/// GSIs (optional, created in Terraform):
///   gsi_updated: PK=_all, SK=updatedAt   -> paginated listing newest-first
///   gsi_download: PK=_all, SK=download   -> sort by downloads
///
/// queryPackages with keyword falls back to a filtered scan if no GSI hit.
class DynamoMetaStore extends MetaStore {
  final DynamoClient client;
  final String table;
  final String? listIndexName;
  final String? downloadIndexName;

  DynamoMetaStore({
    required this.client,
    required this.table,
    this.listIndexName = 'gsi_updated',
    this.downloadIndexName = 'gsi_download',
  });

  // ---------------------------------------------------------------------------
  // MetaStore API
  // ---------------------------------------------------------------------------

  @override
  Future<UnpubPackage?> queryPackage(String name) async {
    final res = await client.call('GetItem', {
      'TableName': table,
      'Key': {'name': Ddb.s(name)},
      'ConsistentRead': true,
    });
    final item = res['Item'] as Map<String, dynamic>?;
    if (item == null) return null;
    return _itemToPackage(item);
  }

  @override
  Future<void> addVersion(String name, UnpubVersion version) async {
    final versionJson = version.toJson();
    final createdAtIso = version.createdAt.toUtc().toIso8601String();

    final updateExpression = StringBuffer(
        'SET versions = list_append(if_not_exists(versions, :empty), :v), '
        'updatedAt = :ts, '
        'latestVersion = :lv, '
        'createdAt = if_not_exists(createdAt, :ts), '
        'private = if_not_exists(private, :true), '
        '#all = :all');
    final expressionAttributeNames = <String, String>{'#all': '_all'};
    final expressionAttributeValues = <String, dynamic>{
      ':v': Ddb.list([Ddb.map(_normalizeForDdb(versionJson))]),
      ':empty': Ddb.list(const <Map<String, dynamic>>[]),
      ':ts': Ddb.s(createdAtIso),
      ':lv': Ddb.s(version.version),
      ':true': Ddb.b(true),
      ':all': Ddb.s('1'),
    };

    if (version.uploader != null) {
      updateExpression.write(' ADD uploaders :uploader, download :zero');
      expressionAttributeValues[':uploader'] = Ddb.ss({version.uploader!});
      expressionAttributeValues[':zero'] = Ddb.n(0);
    } else {
      updateExpression.write(' ADD download :zero');
      expressionAttributeValues[':zero'] = Ddb.n(0);
    }

    await client.call('UpdateItem', {
      'TableName': table,
      'Key': {'name': Ddb.s(name)},
      'UpdateExpression': updateExpression.toString(),
      'ExpressionAttributeNames': expressionAttributeNames,
      'ExpressionAttributeValues': expressionAttributeValues,
    });
  }

  @override
  Future<void> addUploader(String name, String email) async {
    await client.call('UpdateItem', {
      'TableName': table,
      'Key': {'name': Ddb.s(name)},
      'UpdateExpression': 'ADD uploaders :u SET updatedAt = :ts',
      'ConditionExpression': 'attribute_exists(#name)',
      'ExpressionAttributeNames': {'#name': 'name'},
      'ExpressionAttributeValues': {
        ':u': Ddb.ss({email}),
        ':ts': Ddb.s(DateTime.now().toUtc().toIso8601String()),
      },
    });
  }

  @override
  Future<void> removeUploader(String name, String email) async {
    await client.call('UpdateItem', {
      'TableName': table,
      'Key': {'name': Ddb.s(name)},
      'UpdateExpression': 'DELETE uploaders :u SET updatedAt = :ts',
      'ConditionExpression': 'attribute_exists(#name)',
      'ExpressionAttributeNames': {'#name': 'name'},
      'ExpressionAttributeValues': {
        ':u': Ddb.ss({email}),
        ':ts': Ddb.s(DateTime.now().toUtc().toIso8601String()),
      },
    });
  }

  @override
  void increaseDownloads(String name, String version) {
    // Fire-and-forget atomic counter increment.
    client.call('UpdateItem', {
      'TableName': table,
      'Key': {'name': Ddb.s(name)},
      'UpdateExpression': 'ADD download :one',
      'ExpressionAttributeValues': {':one': Ddb.n(1)},
    }).catchError((_) => <String, dynamic>{});
  }

  @override
  Future<UnpubQueryResult> queryPackages({
    required int size,
    required int page,
    required String sort,
    String? keyword,
    String? uploader,
    String? dependency,
  }) async {
    final useDownloadIndex = sort == 'download' && downloadIndexName != null;
    final useUpdatedIndex = !useDownloadIndex && listIndexName != null;

    // Fetch enough items to satisfy `page * size` + buffer; we paginate
    // client-side because Dynamo cursors are stateless across calls.
    final desired = (page + 1) * size;
    final filterBuffer = StringBuffer();
    final exprValues = <String, dynamic>{':all': Ddb.s('1')};
    final exprNames = <String, String>{};

    if (keyword != null && keyword.isNotEmpty) {
      filterBuffer.write('contains(#nm, :kw)');
      exprNames['#nm'] = 'name';
      exprValues[':kw'] = Ddb.s(keyword);
    }
    if (uploader != null) {
      if (filterBuffer.isNotEmpty) filterBuffer.write(' AND ');
      filterBuffer.write('contains(uploaders, :uploader)');
      exprValues[':uploader'] = Ddb.s(uploader);
    }

    final items = <Map<String, dynamic>>[];
    String? nextToken;
    while (items.length < desired) {
      final payload = <String, dynamic>{
        'TableName': table,
        'KeyConditionExpression': '#all = :all',
        'ExpressionAttributeValues': exprValues,
        'ExpressionAttributeNames': {
          '#all': '_all',
          ...exprNames,
        },
        'ScanIndexForward': false,
        'Limit': desired - items.length,
        if (useDownloadIndex) 'IndexName': downloadIndexName,
        if (useUpdatedIndex) 'IndexName': listIndexName,
        if (filterBuffer.isNotEmpty) 'FilterExpression': filterBuffer.toString(),
        if (nextToken != null) 'ExclusiveStartKey': _decodeToken(nextToken),
      };
      final res = await client.call('Query', payload);
      final batch =
          (res['Items'] as List? ?? const []).cast<Map<String, dynamic>>();
      items.addAll(batch);
      final lek = res['LastEvaluatedKey'] as Map<String, dynamic>?;
      if (lek == null) break;
      nextToken = _encodeToken(lek);
    }

    final packages = items.map(_itemToPackage).toList();
    final filtered = dependency == null
        ? packages
        : packages.where((p) {
            return p.versions.any((v) {
              final deps = (v.pubspec['dependencies'] as Map?) ?? const {};
              return deps.containsKey(dependency);
            });
          }).toList();

    final total = filtered.length;
    final start = page * size;
    final end = (start + size).clamp(0, total);
    final pageItems = start >= total ? <UnpubPackage>[] : filtered.sublist(start, end);
    return UnpubQueryResult(total, pageItems);
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  UnpubPackage _itemToPackage(Map<String, dynamic> item) {
    final decoded = Ddb.decodeItem(item);
    final versions = (decoded['versions'] as List? ?? const [])
        .cast<Map<String, dynamic>>()
        .map((m) => UnpubVersion.fromJson(_restoreFromDdb(m)))
        .toList();
    final uploaders = (decoded['uploaders'] as List?)?.cast<String>();
    return UnpubPackage(
      decoded['name'] as String,
      versions,
      (decoded['private'] as bool?) ?? true,
      uploaders,
      DateTime.parse(decoded['createdAt'] as String),
      DateTime.parse(decoded['updatedAt'] as String),
      (decoded['download'] as int?) ?? 0,
    );
  }

  /// Dynamo cannot store empty strings as keys-of-empty-maps cleanly; do a
  /// best-effort scrub of incompatible JSON values (nulls become absent, NaN
  /// becomes 0).
  Map<String, dynamic> _normalizeForDdb(Map<String, dynamic> input) {
    final out = <String, dynamic>{};
    input.forEach((k, v) {
      if (v == null) return;
      if (v is double && (v.isNaN || v.isInfinite)) return;
      out[k] = v;
    });
    return out;
  }

  /// Inverse of [_normalizeForDdb] — currently a passthrough but kept as a hook.
  Map<String, dynamic> _restoreFromDdb(Map<String, dynamic> input) => input;

  String _encodeToken(Map<String, dynamic> lek) =>
      base64Url.encode(utf8.encode(json.encode(lek)));

  Map<String, dynamic> _decodeToken(String token) =>
      json.decode(utf8.decode(base64Url.decode(token))) as Map<String, dynamic>;
}
