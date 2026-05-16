import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'aws_credentials.dart';

/// Minimal AWS SigV4 signer for HTTPS requests.
///
/// Supports header-based signing for S3, STS, DynamoDB and any
/// other AWS service that follows the standard signing process.
class SigV4Signer {
  final String region;
  final String service;
  final AwsCredentials credentials;

  SigV4Signer({
    required this.region,
    required this.service,
    required this.credentials,
  });

  http.Request sign(http.Request request, {List<int>? payloadBytes}) {
    final now = DateTime.now().toUtc();
    final amzDate = _amzDate(now);
    final shortDate = amzDate.substring(0, 8);

    final payload = payloadBytes ?? utf8.encode(request.body);
    final payloadHash = _sha256Hex(payload);

    request.headers['host'] = request.url.hasPort
        ? '${request.url.host}:${request.url.port}'
        : request.url.host;
    request.headers['x-amz-date'] = amzDate;
    request.headers['x-amz-content-sha256'] = payloadHash;
    if (credentials.awsSessionToken != null &&
        credentials.awsSessionToken!.isNotEmpty) {
      request.headers['x-amz-security-token'] = credentials.awsSessionToken!;
    }

    final canonicalUri = _canonicalUri(request.url.path);
    final canonicalQuery = _canonicalQueryString(request.url.queryParameters);

    final sortedHeaderKeys = request.headers.keys
        .map((k) => k.toLowerCase())
        .toList()
      ..sort();
    final canonicalHeaders = sortedHeaderKeys
        .map((k) => '$k:${request.headers[_findHeaderKey(request.headers, k)]?.trim()}\n')
        .join();
    final signedHeaders = sortedHeaderKeys.join(';');

    final canonicalRequest = [
      request.method.toUpperCase(),
      canonicalUri,
      canonicalQuery,
      canonicalHeaders,
      signedHeaders,
      payloadHash,
    ].join('\n');

    final credentialScope = '$shortDate/$region/$service/aws4_request';
    final stringToSign = [
      'AWS4-HMAC-SHA256',
      amzDate,
      credentialScope,
      _sha256Hex(utf8.encode(canonicalRequest)),
    ].join('\n');

    final kDate = _hmacSha256(
        utf8.encode('AWS4${credentials.awsSecretAccessKey}'), shortDate);
    final kRegion = _hmacSha256(kDate, region);
    final kService = _hmacSha256(kRegion, service);
    final kSigning = _hmacSha256(kService, 'aws4_request');
    final signature = _toHex(_hmacSha256(kSigning, stringToSign));

    final authHeader = 'AWS4-HMAC-SHA256 '
        'Credential=${credentials.awsAccessKeyId}/$credentialScope, '
        'SignedHeaders=$signedHeaders, '
        'Signature=$signature';
    request.headers['authorization'] = authHeader;

    return request;
  }

  static String _amzDate(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${t.year}${two(t.month)}${two(t.day)}'
        'T${two(t.hour)}${two(t.minute)}${two(t.second)}Z';
  }

  static String _sha256Hex(List<int> bytes) => _toHex(sha256.convert(bytes).bytes);

  static List<int> _hmacSha256(List<int> key, String data) =>
      Hmac(sha256, key).convert(utf8.encode(data)).bytes;

  static String _toHex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  static String _canonicalUri(String path) {
    if (path.isEmpty) return '/';
    // S3 requires unencoded path segments; STS/DDB encode segments.
    return path
        .split('/')
        .map((segment) => Uri.encodeQueryComponent(segment).replaceAll('+', '%20'))
        .join('/')
        .replaceAll('%2F', '/');
  }

  static String _canonicalQueryString(Map<String, String> params) {
    final entries = params.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    return entries
        .map((e) =>
            '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}')
        .join('&');
  }

  static String? _findHeaderKey(Map<String, String> headers, String lower) {
    for (final k in headers.keys) {
      if (k.toLowerCase() == lower) return k;
    }
    return null;
  }
}
