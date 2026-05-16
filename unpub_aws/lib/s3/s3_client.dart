import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

import '../core/credential_chain.dart';
import '../core/sigv4.dart';

/// Minimal S3 client supporting conditional writes (If-Match / If-None-Match),
/// GetObject, ListObjectsV2, DeleteObject.
///
/// Uses raw HTTPS + SigV4 so we can set the conditional headers the high-level
/// minio client does not expose.
class S3Client {
  final String bucket;
  final String region;
  final String endpoint;
  final AwsCredentialChain credentials;
  final bool pathStyle;
  final http.Client _http;

  S3Client({
    required this.bucket,
    required this.region,
    required this.credentials,
    String? endpoint,
    bool? pathStyle,
    http.Client? client,
  })  : endpoint = endpoint ?? 'https://s3.$region.amazonaws.com',
        pathStyle = pathStyle ?? !_endpointSupportsVirtualHost(endpoint),
        _http = client ?? http.Client();

  static bool _endpointSupportsVirtualHost(String? endpoint) {
    if (endpoint == null) return true;
    final uri = Uri.parse(endpoint);
    return uri.host.endsWith('amazonaws.com');
  }

  Uri _objectUri(String key) {
    final base = Uri.parse(endpoint);
    if (pathStyle) {
      return base.replace(path: '/$bucket/$key');
    }
    return base.replace(host: '$bucket.${base.host}', path: '/$key');
  }

  Uri _bucketUri([Map<String, String>? query]) {
    final base = Uri.parse(endpoint);
    if (pathStyle) {
      return base.replace(path: '/$bucket', queryParameters: query);
    }
    return base.replace(
        host: '$bucket.${base.host}', path: '/', queryParameters: query);
  }

  /// HEAD request — same shape as [getObject] minus the body. Useful for
  /// existence checks (e.g. [PackageStore.exists]).
  Future<bool> headObject(String key) async {
    final req = http.Request('HEAD', _objectUri(key));
    final res = await _send(req);
    if (res.statusCode == 404) return false;
    if (res.statusCode != 200) {
      throw S3Exception('HeadObject', key, res.statusCode, res.body);
    }
    return true;
  }

  Future<S3ObjectResponse> getObject(String key) async {
    final req = http.Request('GET', _objectUri(key));
    final res = await _send(req);
    if (res.statusCode == 404) {
      return S3ObjectResponse.notFound();
    }
    if (res.statusCode != 200) {
      throw S3Exception('GetObject', key, res.statusCode, res.body);
    }
    return S3ObjectResponse(
      body: res.bodyBytes,
      etag: res.headers['etag'],
      contentType: res.headers['content-type'],
    );
  }

  /// PUT object. Set [ifMatch] or [ifNoneMatch] for conditional writes.
  /// `ifNoneMatch: '*'` = fail if key already exists (immutable create).
  Future<String> putObject(
    String key,
    List<int> body, {
    String? contentType,
    String? ifMatch,
    String? ifNoneMatch,
  }) async {
    final req = http.Request('PUT', _objectUri(key));
    req.bodyBytes = body;
    if (contentType != null) req.headers['content-type'] = contentType;
    if (ifMatch != null) req.headers['if-match'] = ifMatch;
    if (ifNoneMatch != null) req.headers['if-none-match'] = ifNoneMatch;
    final res = await _send(req, payloadBytes: body);
    if (res.statusCode == 412) {
      throw S3PreconditionFailed(key);
    }
    if (res.statusCode ~/ 100 != 2) {
      throw S3Exception('PutObject', key, res.statusCode, res.body);
    }
    return res.headers['etag'] ?? '';
  }

  Future<void> deleteObject(String key) async {
    final req = http.Request('DELETE', _objectUri(key));
    final res = await _send(req);
    if (res.statusCode ~/ 100 != 2 && res.statusCode != 404) {
      throw S3Exception('DeleteObject', key, res.statusCode, res.body);
    }
  }

  /// ListObjectsV2 with optional prefix and delimiter.
  Future<S3ListResult> listObjects({
    String? prefix,
    String? delimiter,
    String? continuationToken,
    int maxKeys = 1000,
  }) async {
    final query = <String, String>{
      'list-type': '2',
      'max-keys': maxKeys.toString(),
      if (prefix != null) 'prefix': prefix,
      if (delimiter != null) 'delimiter': delimiter,
      if (continuationToken != null) 'continuation-token': continuationToken,
    };
    final req = http.Request('GET', _bucketUri(query));
    final res = await _send(req);
    if (res.statusCode != 200) {
      throw S3Exception('ListObjectsV2', bucket, res.statusCode, res.body);
    }
    return S3ListResult.fromXml(res.body);
  }

  Future<http.Response> _send(http.Request req, {List<int>? payloadBytes}) async {
    final creds = await credentials.resolve();
    final signer = SigV4Signer(
      region: region,
      service: 's3',
      credentials: creds,
    );
    signer.sign(req, payloadBytes: payloadBytes ?? req.bodyBytes);
    final streamed = await _http.send(req);
    return http.Response.fromStream(streamed);
  }

  void close() => _http.close();
}

class S3ObjectResponse {
  final List<int>? body;
  final String? etag;
  final String? contentType;
  final bool exists;

  S3ObjectResponse({this.body, this.etag, this.contentType}) : exists = true;
  S3ObjectResponse.notFound()
      : body = null,
        etag = null,
        contentType = null,
        exists = false;

  String? bodyAsString() {
    if (body == null) return null;
    return utf8.decode(body!);
  }
}

class S3ListResult {
  final List<S3ListEntry> contents;
  final List<String> commonPrefixes;
  final bool isTruncated;
  final String? nextContinuationToken;

  S3ListResult({
    required this.contents,
    required this.commonPrefixes,
    required this.isTruncated,
    this.nextContinuationToken,
  });

  factory S3ListResult.fromXml(String body) {
    final doc = XmlDocument.parse(body);
    final root = doc.rootElement;
    return S3ListResult(
      contents: root.findElements('Contents').map((e) {
        return S3ListEntry(
          key: e.getElement('Key')!.innerText,
          size: int.tryParse(e.getElement('Size')?.innerText ?? '0') ?? 0,
          etag: e.getElement('ETag')?.innerText,
          lastModified: DateTime.tryParse(
              e.getElement('LastModified')?.innerText ?? ''),
        );
      }).toList(),
      commonPrefixes: root
          .findElements('CommonPrefixes')
          .map((e) => e.getElement('Prefix')!.innerText)
          .toList(),
      isTruncated:
          (root.getElement('IsTruncated')?.innerText ?? 'false') == 'true',
      nextContinuationToken: root.getElement('NextContinuationToken')?.innerText,
    );
  }
}

class S3ListEntry {
  final String key;
  final int size;
  final String? etag;
  final DateTime? lastModified;

  S3ListEntry({
    required this.key,
    required this.size,
    this.etag,
    this.lastModified,
  });
}

class S3Exception implements Exception {
  final String op;
  final String key;
  final int statusCode;
  final String body;

  S3Exception(this.op, this.key, this.statusCode, this.body);

  @override
  String toString() => 'S3Exception($op $key): $statusCode $body';
}

class S3PreconditionFailed extends S3Exception {
  S3PreconditionFailed(String key)
      : super('PutObject', key, HttpStatus.preconditionFailed, '');

  @override
  String toString() => 'S3PreconditionFailed: $key';
}
