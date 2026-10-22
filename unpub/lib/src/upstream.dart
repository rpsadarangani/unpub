import 'dart:convert';

import 'package:http/http.dart' as http;

/// A pub repository unpub mirrors from (pub.dev, Cloudsmith, Artifactory,
/// another unpub, …). Credentials are only ever sent to this upstream's own
/// origin — never forwarded across redirects to signed CDN / storage hosts.
class Upstream {
  /// Short name; clients pin a dependency to this upstream with
  /// `hosted: <unpub>/u/<name>/`. Lowercase letters, digits, `_` and `-`.
  final String name;

  /// Repository base URL, including any path prefix
  /// (e.g. `https://dart.cloudsmith.io/<org>/<repo>/`).
  final Uri base;

  /// Bearer token (`dart pub token add` style). Takes precedence over basic.
  final String? token;
  final String? username;
  final String? password;

  Upstream(String url,
      {required this.name, this.token, this.username, this.password})
      : base = Uri.parse(url.endsWith('/') ? url : '$url/') {
    if (!RegExp(r'^[a-z0-9_-]+$').hasMatch(name)) {
      throw ArgumentError.value(name, 'name',
          'upstream names may only use lowercase letters, digits, _ and -');
    }
  }

  /// Uploader recorded on packages mirrored from this upstream. Also used to
  /// find the upstream a cached package came from when refreshing it.
  String get uploaderEmail {
    final path = base.path.replaceAll(RegExp(r'/+$'), '');
    return 'upstream@${base.host}$path';
  }

  /// Resolve [path] relative to [base], keeping any path prefix.
  Uri resolve(String path) =>
      base.resolve(path.startsWith('/') ? path.substring(1) : path);

  Map<String, String> get _authHeaders {
    if (token != null && token!.isNotEmpty) {
      return {'authorization': 'Bearer $token'};
    }
    if (username != null && username!.isNotEmpty) {
      final raw = utf8.encode('$username:${password ?? ''}');
      return {'authorization': 'Basic ${base64.encode(raw)}'};
    }
    return const {};
  }

  bool _sameOrigin(Uri url) =>
      url.scheme == base.scheme &&
      url.host == base.host &&
      url.port == base.port;

  /// GET [url], following up to [maxRedirects] redirects. The auth header is
  /// attached only while the request targets this upstream's origin.
  Future<http.Response> get(
    http.Client client,
    Uri url, {
    Map<String, String> headers = const {},
    int maxRedirects = 5,
  }) async {
    var current = url;
    for (var i = 0; i <= maxRedirects; i++) {
      final req = http.Request('GET', current)
        ..followRedirects = false
        ..headers.addAll(headers);
      if (_sameOrigin(current)) req.headers.addAll(_authHeaders);
      final res = await http.Response.fromStream(await client.send(req));
      final location = res.headers['location'];
      if (res.statusCode ~/ 100 == 3 && location != null) {
        current = current.resolve(location);
        continue;
      }
      return res;
    }
    throw 'upstream ${base.host}: too many redirects for $url';
  }

  @override
  String toString() => '$name ($base)';
}
