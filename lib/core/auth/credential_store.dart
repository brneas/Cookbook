import 'package:flutter_secure_storage/flutter_secure_storage.dart';

final class AppCredentials {
  const AppCredentials(this.loginName, this.appPassword);
  final String loginName;
  final String appPassword;
  @override
  String toString() => 'AppCredentials([redacted])';
}

abstract interface class CredentialStore {
  Future<void> write(String accountId, String appPassword);
  Future<String?> read(String accountId);
  Future<void> delete(String accountId);
}

final class PlatformCredentialStore implements CredentialStore {
  PlatformCredentialStore([FlutterSecureStorage? storage])
    : _storage = storage ?? const FlutterSecureStorage();
  final FlutterSecureStorage _storage;
  String _key(String id) => 'cookbook.app-password.$id';
  @override
  Future<void> write(String accountId, String appPassword) =>
      _storage.write(key: _key(accountId), value: appPassword);
  @override
  Future<String?> read(String accountId) => _storage.read(key: _key(accountId));
  @override
  Future<void> delete(String accountId) =>
      _storage.delete(key: _key(accountId));
}
