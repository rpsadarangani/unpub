import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:googleapis_auth/googleapis_auth.dart';

class Credential {
  String accessToken;
  String refreshToken;
  String idToken;
  String tokenEndpoint;
  List<String> scopes;
  int expiration;

  Credential(this.accessToken, this.refreshToken, this.idToken,
      this.tokenEndpoint, this.scopes, this.expiration);

  Credential.fromMap(Map<String, dynamic> map)
      : accessToken = map['accessToken'],
        refreshToken = map['refreshToken'],
        idToken = map['idToken'],
        tokenEndpoint = map['tokenEndpoint'],
        scopes = List<String>.from(map['scopes']),
        expiration = map['expiration'];

  /// Convenient constructor.
  ///
  /// It's used to convert an AccessCredentials instance to Credential.
  /// AccessCredentials is from googleapis_auth
  Credential.fromAccessCredentials(
      AccessCredentials accessCredentials, String? tokenEndpoint)
      : accessToken = accessCredentials.accessToken.data,
        refreshToken = accessCredentials.refreshToken ?? '',
        idToken = accessCredentials.idToken ?? '',
        tokenEndpoint =
            tokenEndpoint ?? 'https://accounts.google.com/o/oauth2/token',
        scopes = accessCredentials.scopes,
        expiration =
            accessCredentials.accessToken.expiry.millisecondsSinceEpoch;

  String toJsonString() {
    return json.encode({
      'accessToken': accessToken,
      'refreshToken': refreshToken,
      'idToken': idToken,
      'tokenEndpoint': tokenEndpoint,
      'scopes': scopes,
      'expiration': expiration
    });
  }

  @override
  String toString() {
    return toJsonString();
  }

  @override
  bool operator ==(other) =>
      other is Credential &&
      accessToken == other.accessToken &&
      refreshToken == other.refreshToken &&
      idToken == other.idToken &&
      tokenEndpoint == other.tokenEndpoint &&
      ListEquality().equals(scopes, other.scopes) &&
      expiration == other.expiration;

  @override
  int get hashCode => Object.hash(
      accessToken, refreshToken, idToken, tokenEndpoint, scopes, expiration);
}
