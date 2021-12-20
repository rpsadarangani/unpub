import 'dart:io';

import 'package:unpub_auth/unpub_auth.dart' as unpub_auth;

void main(List<String> arguments) async {
  await unpub_auth.run();
  exit(0);
}
