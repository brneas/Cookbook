import 'package:sqflite/sqflite.dart';
import '../../../core/auth/nextcloud_verification.dart';
import '../../../core/auth/auth_diagnostics.dart';
import 'dart:convert';
import 'dart:math';
import '../../../core/api/cookbook_capabilities.dart';
import '../../../core/auth/credential_store.dart';
import '../../../core/auth/nextcloud_auth_service.dart';
import '../../../core/database/app_database.dart';
import '../../../core/errors/app_failure.dart';
import '../../../core/networking/nextcloud_client.dart';
import '../../../core/networking/server_address.dart';

final class Account {
  const Account(this.id, this.server, this.loginName, {this.capabilities});
  final String id, loginName;
  final ServerAddress server;
  final CookbookCapabilities? capabilities;
}

final class AccountRepository {
  AccountRepository(this.database, this.credentials, {this.clientFactory});
  final AppDatabase database;
  final CredentialStore credentials;
  final Future<NextcloudClient> Function(Account)? clientFactory;
  Future<Account?> load() async {
    final rows = await database.db.query('accounts');
    for (final row in rows.where((r) => r['removing'] == 1)) {
      final id = row['id'] as String;
      await credentials.delete(id);
      await database.removeAccount(id);
    }
    final active = rows.where((r) => r['removing'] == 0);
    if (active.isEmpty) return null;
    final row = active.first;
    final caps = (jsonDecode(row['capabilities'] as String) as Map)
        .cast<String, Object?>();
    return Account(
      row['id'] as String,
      ServerAddress.parse(row['server'] as String),
      row['login_name'] as String,
      capabilities: caps.isEmpty ? null : CookbookCapabilities.fromJson(caps),
    );
  }

  /// Store the one-time login result before discovery, so failed verification is recoverable.
  Future<Account> add(LoginResult login) async {
    if (await load() != null) throw const AppFailure(FailureKind.conflict);
    final random = Random.secure();
    final id = base64UrlEncode(List.generate(24, (_) => random.nextInt(256)));
    await database.db.insert('accounts', {
      'id': id,
      'server': login.server.toString(),
      'login_name': login.credentials.loginName,
      'capabilities': '{}',
    });
    try {
      await credentials.write(id, login.credentials.appPassword);
    } catch (_) {
      await database.removeAccount(id);
      throw const AppFailure(FailureKind.storage);
    }
    return Account(id, login.server, login.credentials.loginName);
  }

  Future<NextcloudClient> client(Account account) async {
    if (clientFactory != null) return clientFactory!(account);
    final secret = await credentials.read(account.id);
    if (secret == null) throw const AppFailure(FailureKind.authentication);
    return NextcloudClient(
      account.server,
      credentials: AppCredentials(account.loginName, secret),
    );
  }

  Future<void> saveCapabilities(
    Account account,
    CookbookCapabilities caps,
  ) async {
    await database.db.update(
      'accounts',
      {'capabilities': jsonEncode(caps.toJson())},
      where: 'id = ?',
      whereArgs: [account.id],
    );
  }

  Future<void> saveNextcloud(Account account, NextcloudInfo info) async {
    await database.db.transaction((tx) async {
      for (final entry in {
        'theme': jsonEncode(info.theme.toJson()),
        if (info.version != null) 'nextcloud_version': info.version!,
      }.entries) {
        await tx.insert('account_metadata', {
          'account_id': account.id,
          'key': entry.key,
          'value': entry.value,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
  }

  Future<void> saveConnectionResult(
    Account account,
    RequestDiagnostic? diagnostic,
  ) async {
    await database.db.transaction((tx) async {
      for (final entry in {
        'last_connection_test': DateTime.now().toUtc().toIso8601String(),
        'last_http_result': diagnostic?.text ?? 'No request result',
      }.entries) {
        await tx.insert('account_metadata', {
          'account_id': account.id,
          'key': entry.key,
          'value': entry.value,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
  }

  // A one-time credential response is checkpointed only in secure storage.
  // No Login Flow challenge/poll token is persisted. Retry resumes verification.
  static const pendingKey = 'pending-login';
  Future<void> checkpoint(LoginResult result) => credentials.write(
    pendingKey,
    jsonEncode({
      'server': result.server.toString(),
      'login': result.credentials.loginName,
      'password': result.credentials.appPassword,
    }),
  );
  Future<LoginResult?> pending(ServerAddress server) async {
    final text = await credentials.read(pendingKey);
    if (text == null) return null;
    try {
      final json = jsonDecode(text) as Map;
      final saved = ServerAddress.parse(json['server'] as String);
      if (saved.toString() != server.toString()) return null;
      return LoginResult(
        saved,
        AppCredentials(json['login'] as String, json['password'] as String),
      );
    } catch (_) {
      throw const AppFailure(FailureKind.storage);
    }
  }

  Future<void> clearCheckpoint() => credentials.delete(pendingKey);

  /// Returns false if remote revocation failed; local removal still completes.
  Future<bool> remove(Account account) async {
    await database.db.update(
      'accounts',
      {'removing': 1},
      where: 'id = ?',
      whereArgs: [account.id],
    );
    var revoked = false;
    NextcloudClient? http;
    try {
      http = await client(account);
      await NextcloudAuthService.revoke(http);
      revoked = true;
    } catch (_) {
      revoked = false;
    } finally {
      http?.close();
    }
    await credentials.delete(account.id);
    await clearCheckpoint();
    await database.removeAccount(account.id);
    return revoked;
  }
}
