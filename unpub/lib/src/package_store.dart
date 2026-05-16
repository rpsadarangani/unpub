import 'dart:async';

abstract class PackageStore {
  bool supportsDownloadUrl = false;

  FutureOr<String> downloadUrl(String name, String version) {
    throw 'downloadUri not implemented';
  }

  Stream<List<int>> download(String name, String version) {
    throw 'download not implemented';
  }

  Future<void> upload(String name, String version, List<int> content);

  /// Cheap check ("does a tarball for `name@version` already live in the
  /// store?") — used by the cache-on-miss path to decide whether to pull
  /// from upstream. Default implementation conservatively returns `false`
  /// so unmodified stores always re-fetch from upstream.
  Future<bool> exists(String name, String version) async => false;
}
