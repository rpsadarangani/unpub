import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/credential_chain.dart';
import '../core/sigv4.dart';

/// Minimal DynamoDB JSON-over-HTTP client.
class DynamoClient {
  final String region;
  final String endpoint;
  final AwsCredentialChain credentials;
  final http.Client _http;

  DynamoClient({
    required this.region,
    required this.credentials,
    String? endpoint,
    http.Client? client,
  })  : endpoint = endpoint ?? 'https://dynamodb.$region.amazonaws.com/',
        _http = client ?? http.Client();

  Future<Map<String, dynamic>> call(
      String target, Map<String, dynamic> payload) async {
    final body = utf8.encode(json.encode(payload));
    final req = http.Request('POST', Uri.parse(endpoint));
    req.bodyBytes = body;
    req.headers['content-type'] = 'application/x-amz-json-1.0';
    req.headers['x-amz-target'] = 'DynamoDB_20120810.$target';

    final creds = await credentials.resolve();
    SigV4Signer(
      region: region,
      service: 'dynamodb',
      credentials: creds,
    ).sign(req, payloadBytes: body);

    final streamed = await _http.send(req);
    final res = await http.Response.fromStream(streamed);
    final decoded = res.body.isEmpty
        ? <String, dynamic>{}
        : json.decode(res.body) as Map<String, dynamic>;
    if (res.statusCode ~/ 100 != 2) {
      throw DynamoException(
        target: target,
        statusCode: res.statusCode,
        type: decoded['__type'] as String? ?? 'Unknown',
        message: decoded['message'] as String? ??
            decoded['Message'] as String? ??
            res.body,
      );
    }
    return decoded;
  }

  void close() => _http.close();
}

class DynamoException implements Exception {
  final String target;
  final int statusCode;
  final String type;
  final String message;

  DynamoException({
    required this.target,
    required this.statusCode,
    required this.type,
    required this.message,
  });

  bool get isConditionalCheckFailed =>
      type.endsWith('ConditionalCheckFailedException');

  bool get isResourceNotFound => type.endsWith('ResourceNotFoundException');

  @override
  String toString() =>
      'DynamoException($target $statusCode $type): $message';
}

/// Conversion helpers between Dart values and DynamoDB AttributeValue JSON.
class Ddb {
  static Map<String, dynamic> s(String v) => {'S': v};
  static Map<String, dynamic> n(num v) => {'N': v.toString()};
  static Map<String, dynamic> b(bool v) => {'BOOL': v};
  static Map<String, dynamic> nullAttr() => {'NULL': true};
  static Map<String, dynamic> ss(Iterable<String> v) => {'SS': v.toList()};
  static Map<String, dynamic> list(Iterable<Map<String, dynamic>> v) =>
      {'L': v.toList()};
  static Map<String, dynamic> map(Map<String, dynamic> v) => {
        'M': {for (final e in v.entries) e.key: encode(e.value)},
      };

  static Map<String, dynamic> encode(dynamic value) {
    if (value == null) return nullAttr();
    if (value is bool) return b(value);
    if (value is num) return n(value);
    if (value is String) return s(value);
    if (value is DateTime) return s(value.toUtc().toIso8601String());
    if (value is List) return list(value.map(encode));
    if (value is Set<String>) return ss(value);
    if (value is Map) {
      return {
        'M': {
          for (final e in value.entries) e.key.toString(): encode(e.value),
        },
      };
    }
    throw ArgumentError('Cannot encode ${value.runtimeType} as DynamoDB attr');
  }

  static dynamic decode(Map<String, dynamic> attr) {
    if (attr.containsKey('NULL')) return null;
    if (attr.containsKey('S')) return attr['S'];
    if (attr.containsKey('N')) {
      final n = attr['N'] as String;
      return n.contains('.') ? double.parse(n) : int.parse(n);
    }
    if (attr.containsKey('BOOL')) return attr['BOOL'];
    if (attr.containsKey('SS')) return (attr['SS'] as List).cast<String>();
    if (attr.containsKey('L')) {
      return (attr['L'] as List)
          .cast<Map<String, dynamic>>()
          .map(decode)
          .toList();
    }
    if (attr.containsKey('M')) {
      final m = attr['M'] as Map<String, dynamic>;
      return m.map((k, v) => MapEntry(k, decode(v as Map<String, dynamic>)));
    }
    throw ArgumentError('Unknown DynamoDB attribute: $attr');
  }

  static Map<String, dynamic> decodeItem(Map<String, dynamic> item) =>
      item.map((k, v) => MapEntry(k, decode(v as Map<String, dynamic>)));
}
