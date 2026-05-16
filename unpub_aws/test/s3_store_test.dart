import 'package:test/test.dart';
import 'package:unpub_aws/unpub_aws.dart';

void main() {
  group('AwsCredentials', () {
    test('manual', () {
      final creds = AwsCredentials(
          awsAccessKeyId: 'specialKey', awsSecretAccessKey: 'specialSecret');
      expect(creds.awsAccessKeyId, 'specialKey');
      expect(creds.awsSecretAccessKey, 'specialSecret');
    });

    test('from env', () {
      final env = {
        'AWS_ACCESS_KEY_ID': 'special-key-id',
        'AWS_SECRET_ACCESS_KEY': 'special-access-key',
      };
      final creds = AwsCredentials(environment: env);
      expect(creds.awsAccessKeyId, env['AWS_ACCESS_KEY_ID']);
      expect(creds.awsSecretAccessKey, env['AWS_SECRET_ACCESS_KEY']);
    });
  });

  group('S3Store', () {
    test('requires a region', () {
      expect(
        () => S3Store(
          'dart-pub-test',
          credentials: AwsCredentialChain(
            override: AwsCredentials(
              awsAccessKeyId: 'x',
              awsSecretAccessKey: 'y',
            ),
            environment: const {},
          ),
          environment: const {},
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('honours explicit region', () {
      final store = S3Store(
        'dart-pub-test',
        region: 'us-east-1',
        credentials: AwsCredentialChain(
          override: AwsCredentials(
            awsAccessKeyId: 'x',
            awsSecretAccessKey: 'y',
          ),
          environment: const {},
        ),
        environment: const {},
      );
      expect(store.region, 'us-east-1');
    });
  });
}
