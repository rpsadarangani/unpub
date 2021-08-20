import 'package:mongo_dart/mongo_dart.dart';
import 'package:intl/intl.dart';
import 'package:unpub/src/models.dart';
import 'meta_store.dart';

final packageCollection = 'packages';
final statsCollection = 'stats';

class MongoStore extends MetaStore {
  Db db;

  MongoStore(this.db);

  static SelectorBuilder _selectByName(String? name) => where.eq('name', name);

  static SelectorBuilder _buildSearchSelector(String? keyword) {
    if (keyword == null || keyword == '') return where;

    final _keywordPrefixes = {
      'email:': (String email) => where.eq('uploaders', email),
      'package:': (String package) => where.match('name', '^$package.*'),
      'dependency:': (String dependency) => where.raw({
            // FIXME: raw
            'versions': {
              '\$elemMatch': {
                'pubspec.dependencies.$dependency': {'\$exists': true}
              }
            }
          }),
    };

    for (var entry in _keywordPrefixes.entries) {
      if (keyword.startsWith(entry.key)) {
        return entry.value(keyword.substring(entry.key.length).trim());
      }
    }

    return where.match('name', '.*$keyword.*');
  }

  Future<UnpubQueryResult> _queryPackagesBySelector(
      SelectorBuilder selector) async {
    final count = await db.collection(packageCollection).count(selector);
    final packages = await db
        .collection(packageCollection)
        .find(selector)
        .map((item) => UnpubPackage.fromJson(item))
        .toList();
    return UnpubQueryResult(count, packages);
  }

  @override
  queryPackage(name) async {
    var json =
        await db.collection(packageCollection).findOne(_selectByName(name));
    if (json == null) return null;
    return UnpubPackage.fromJson(json);
  }

  @override
  addVersion(name, version) async {
    await db.collection(packageCollection).update(
        _selectByName(name),
        modify
            .push('versions', version.toJson())
            .addToSet('uploaders', version.uploader)
            .setOnInsert('createdAt', version.createdAt)
            .setOnInsert('private', true)
            .setOnInsert('download', 0)
            .set('updatedAt', version.createdAt),
        upsert: true);
  }

  @override
  addUploader(name, email) async {
    await db
        .collection(packageCollection)
        .update(_selectByName(name), modify.push('uploaders', email));
  }

  @override
  removeUploader(name, email) async {
    await db
        .collection(packageCollection)
        .update(_selectByName(name), modify.pull('uploaders', email));
  }

  @override
  increaseDownloads(name, version) {
    var today = DateFormat('yyyyMMdd').format(DateTime.now());
    db
        .collection(packageCollection)
        .update(_selectByName(name), modify.inc('download', 1));
    db
        .collection(statsCollection)
        .update(_selectByName(name), modify.inc('d$today', 1));
  }

  @override
  queryPackages(size, page, sort, keyword) async {
    var selector =
        where.sortBy(sort, descending: true).limit(size).skip(page * size);
    if (keyword != null) {
      selector = selector.match('name', '.*$keyword.*');
    }

    return _queryPackagesBySelector(selector);
  }

  @override
  queryPackagesByUploader(size, page, sort, email) {
    var selector = where
        .eq('uploaders', email)
        .sortBy(sort, descending: true)
        .limit(size)
        .skip(page * size);

    return _queryPackagesBySelector(selector);
  }
}
