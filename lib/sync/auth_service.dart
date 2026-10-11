import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class SyncAccount {
  final String id, email;
  const SyncAccount(this.id, this.email);
}

abstract interface class SyncAuth {
  SyncAccount? get account;
  Stream<SyncAccount?> get changes;
  Future<void> signIn(String email, String password);
  Future<void> signOut();
}

class SupabaseSyncAuth implements SyncAuth {
  final SupabaseClient client;
  SupabaseSyncAuth(this.client);
  SyncAccount? _account(User? user) =>
      user == null ? null : SyncAccount(user.id, user.email ?? '');
  @override
  SyncAccount? get account => _account(client.auth.currentUser);
  @override
  Stream<SyncAccount?> get changes => client.auth.onAuthStateChange.map(
    (event) => _account(event.session?.user),
  );
  @override
  Future<void> signIn(String email, String password) async {
    await client.auth
        .signInWithPassword(email: email.trim(), password: password)
        .timeout(const Duration(seconds: 25));
  }

  @override
  Future<void> signOut() => client.auth.signOut(scope: SignOutScope.local);
}

/// Uses Supabase's normal session lifecycle with OS-backed encrypted storage,
/// rather than placing refresh tokens in plain-text preferences or SQLite.
class SecureSessionStorage extends LocalStorage {
  final String key;
  final FlutterSecureStorage storage;
  const SecureSessionStorage(
    this.key, {
    this.storage = const FlutterSecureStorage(),
  });
  @override
  Future<void> initialize() async {}
  @override
  Future<bool> hasAccessToken() => storage.containsKey(key: key);
  @override
  Future<String?> accessToken() => storage.read(key: key);
  @override
  Future<void> persistSession(String persistSessionString) =>
      storage.write(key: key, value: persistSessionString);
  @override
  Future<void> removePersistedSession() => storage.delete(key: key);
}
