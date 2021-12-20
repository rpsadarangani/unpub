import 'dart:convert';
import 'dart:io';

import 'credential.dart';
import 'utils.dart';
import 'package:http/http.dart' as http;
import 'package:googleapis_auth/googleapis_auth.dart';

/// The pub client's OAuth2 identifier.
///
/// It's from [dart-lang/pub/lib/src/oauth2.dart](https://github.com/dart-lang/pub/blob/400f21e9883ce6555b66d3ef82f0b732ba9b9fc8/lib/src/oauth2.dart#L21:L22)
const _identifier = '818368855108-8grd2eg9tj9f38os6f1urbcvsq399u8n.apps.'
    'googleusercontent.com';

/// The pub client's OAuth2 secret.
///
/// This isn't actually meant to be kept a secret.
///
/// It's from [dart-lang/pub/lib/src/oauth2.dart](https://github.com/dart-lang/pub/blob/400f21e9883ce6555b66d3ef82f0b732ba9b9fc8/lib/src/oauth2.dart#L27)
const _secret = 'SWeqj8seoJW0w7_CpEPFLX0K';

Future<void> run() async {
  final credential = await readCredentialFromLocal();
  final accessCredentials = await refreshCredential(credential);
  final newCredential = Credential.fromAccessCredentials(
      accessCredentials, credential.tokenEndpoint);
  await writeNewCredential(newCredential);
  outputNewAccessToken(newCredential);
  return;
}

/// Output the new accessToken to stdout.
void outputNewAccessToken(Credential credential) {
  stdout.writeln(credential.accessToken);
}

/// Write new credential to pub-credentials.json.
Future<void> writeNewCredential(Credential credential) async {
  final jsonString = credential.toJsonString();
  final credentialFile = File(Utils.credentialsFilePath);
  await credentialFile.writeAsString(jsonString);
}

/// Refresh credential.
///
/// `AccessCredentials` is from googleapis_auth,
/// there's a convenient constructor in ./credential.dart
Future<AccessCredentials> refreshCredential(Credential credential) async {
  final client = http.Client();
  final clientId = ClientId(_identifier, _secret);
  final accessToken = AccessToken('Bearer', credential.accessToken,
      DateTime.fromMillisecondsSinceEpoch(credential.expiration).toUtc());
  final accessCredentials = AccessCredentials(
      accessToken, credential.refreshToken, credential.scopes,
      idToken: credential.idToken);
  final newCredentials =
      await refreshCredentials(clientId, accessCredentials, client);
  newCredentials.toJson();
  return newCredentials;
}

/// Read credential file from local path.
Future<Credential> readCredentialFromLocal() async {
  final credentialFile = File(Utils.credentialsFilePath);
  final exists = await credentialFile.exists();
  if (!exists) {
    throw '''${Utils.credentialsFilePath} is not exist.
Please run `dart pub login` first''';
  }

  final fileContent = await credentialFile.readAsString();
  late final Map<String, dynamic> credential;
  try {
    credential = json.decode(fileContent) as Map<String, dynamic>;
  } catch (e) {
    throw '''${Utils.credentialsFilePath} is not a JSON, please check the file content.
Detail: ${e.toString()}''';
  }

  return Credential.fromMap(credential);
}
