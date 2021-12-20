import 'package:googleapis_auth/googleapis_auth.dart';
import 'package:test/test.dart';
import '../lib/credential.dart';

void main() {
  group('Credential', () {
    test(
        'Instance created by default constructor is equal to the convenient constructor one.',
        () {
      final nowDt = DateTime.now();
      final credential = Credential('accessToken', 'refreshToken', 'idToken',
          'tokenEndpoint', ['scopes'], nowDt.toUtc().millisecondsSinceEpoch);

      final accessToken = AccessToken('Bearer', 'accessToken',
          DateTime.fromMillisecondsSinceEpoch(credential.expiration).toUtc());
      final accessCredentials = AccessCredentials(
          accessToken, 'refreshToken', ['scopes'],
          idToken: 'idToken');
      final convenientOne =
          Credential.fromAccessCredentials(accessCredentials, 'tokenEndpoint');

      expect(convenientOne == credential, isTrue);
    });

    test(
        'Instance created by default constructor is equal to the Map constructor one.',
        () {
      final nowDt = DateTime.now();
      final credential = Credential('accessToken', 'refreshToken', 'idToken',
          'tokenEndpoint', ['scopes'], nowDt.toUtc().millisecondsSinceEpoch);

      final convenientOne = Credential.fromMap({
        'accessToken': 'accessToken',
        'refreshToken': 'refreshToken',
        'idToken': 'idToken',
        'tokenEndpoint': 'tokenEndpoint',
        'scopes': ['scopes'],
        'expiration': nowDt.toUtc().millisecondsSinceEpoch
      });

      expect(convenientOne == credential, isTrue);
    });
  });
}
