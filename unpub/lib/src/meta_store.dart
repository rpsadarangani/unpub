import 'package:unpub/src/models.dart';

abstract class MetaStore {
  Future<UnpubPackage?> queryPackage(String name);

  Future<void> addVersion(String name, UnpubVersion version);

  Future<void> addUploader(String name, String email);

  Future<void> removeUploader(String name, String email);

  void increaseDownloads(String name, String version);

  Future<UnpubQueryResult> queryPackages(
      int size, int page, String sort, String? keyword);

  Future<UnpubQueryResult> queryPackagesByUploader(
      int size, int page, String sort, String email);

  Future<UnpubQueryResult> queryPackagesByDependency(
      int size, int page, String sort, String dependency);
}
