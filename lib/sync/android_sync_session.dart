import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart';
import 'package:http/io_client.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'auth_service.dart';
import 'supabase_gateway.dart';
import 'sync_gate.dart';
import 'sync_gateway.dart';
import 'sync_store.dart';

/// On Android, secure storage is the session source for both Flutter engines
class AndroidSyncSession implements CoordinatedSyncAuth {
  static const signingOutKey = 'android_signing_out';
  static const _foregroundWait = Duration(seconds: 5);
  static const _signOutWait = Duration(seconds: 35);
  static const _requestTimeout = Duration(seconds: 20);

  final SyncStore store;
  final SyncGate gate;
  final SupabaseConfiguration configuration;
  final LocalStorage storage;
  final bool headless;
  final _changes = StreamController<SyncAccount?>.broadcast();
  final _SyncTransport _transport;
  String get _baseUrl => configuration.url.replaceFirst(RegExp(r'/$'), '');
  late final _auth = GoTrueClient(
    url: '$_baseUrl/auth/v1',
    headers: {
      'apikey': configuration.publishableKey,
      'Authorization': 'Bearer ${configuration.publishableKey}',
    },
    httpClient: _transport,
    autoRefreshToken: false,
  );
  late final _cloud = SupabaseClient(
    _baseUrl,
    configuration.publishableKey,
    httpClient: _transport,
    authOptions: const AuthClientOptions(autoRefreshToken: false),
    postgrestOptions: const PostgrestClientOptions(
      retryEnabled: false,
      requestTimeout: _requestTimeout,
    ),
    accessToken: () async => _auth.currentSession?.accessToken,
  );

  AndroidSyncSession({
    required this.store,
    required this.gate,
    required this.configuration,
    required this.storage,
    this.headless = false,
    Client Function()? createHttpClient,
  }) : _transport = _SyncTransport(createHttpClient);

  SupabaseSyncGateway get gateway => SupabaseSyncGateway(_cloud);

  SyncAccount? _account;
  @override
  SyncAccount? get account => _account;
  @override
  Stream<SyncAccount?> get changes => _changes.stream;

  void _setAccount(User? user) {
    if (user?.id == _account?.id) return;
    _account = user == null ? null : SyncAccount(user.id, user.email ?? '');
    _changes.add(_account);
  }

  Future<Session?> _readSession() async {
    final saved = await storage.accessToken();
    if (saved == null) return null;
    try {
      final session = Session.fromJson(jsonDecode(saved));
      return session != null && _matchesToken(session) ? session : null;
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
  }

  bool _matchesToken(Session session) {
    final parts = session.accessToken.split('.');
    if (session.expiresAt == null || parts.length != 3) return false;
    try {
      final claims = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
      );
      return claims is Map<String, dynamic> && claims['sub'] == session.user.id;
    } on FormatException {
      return false;
    }
  }

  bool get _signingOut => store.meta(signingOutKey).isNotEmpty;

  Future<void> restore() => gate.run(
    () async {
      if (_signingOut) {
        await storage.removePersistedSession();
        store.setMeta(signingOutKey, '');
        return;
      }
      final session = await _readSession();
      if (session == null) return;
      store.checkBinding(session.user.id, configuration.url);
      _setAccount(session.user);
    },
    wait: const Duration(seconds: 95),
    active: () => true,
  );

  @override
  Future<void> signIn(String email, String password) async {
    await gate.run(
      () async {
        _transport.start(() => !_signingOut);
        try {
          final response = await _auth.signInWithPassword(
            email: email.trim(),
            password: password,
          );
          final session = response.session;
          if (session == null || !_matchesToken(session) || session.isExpired) {
            throw AuthSessionMissingException();
          }
          store.bind(session.user.id, configuration.url);
          await storage.persistSession(jsonEncode(session.toJson()));
          _setAccount(session.user);
        } finally {
          _transport.close();
        }
      },
      wait: _foregroundWait,
      active: () => !_signingOut,
    );
  }

  @override
  Future<void> signOut() async {
    // The worker observes this before its next request or database commit
    store.setMeta(signingOutKey, '1');
    abortRequests();
    await gate.run(
      () async {
        final session = await _readSession();
        await storage.removePersistedSession();
        _setAccount(null);
        store.setMeta(signingOutKey, '');
        if (session == null) return;
        _transport.start(() => true);
        try {
          await _auth.setInitialSession(jsonEncode(session.toJson()));
          await _auth.signOut(scope: SignOutScope.local);
        } finally {
          _transport.close();
        }
      },
      wait: _signOutWait,
      active: () => true,
    );
  }

  @override
  Future<void> withSession(
    String accountId,
    bool Function() active,
    Future<void> Function() action,
  ) async {
    bool allowed() => active() && !_signingOut;
    await gate.run(
      () async {
        _transport.start(allowed);
        try {
          final session = await _readSession();
          if (!allowed()) throw SyncCancelled();
          if (session == null || session.user.id != accountId) {
            _setAccount(null);
            throw SyncCancelled();
          }
          store.checkBinding(accountId, configuration.url);
          await _auth.setInitialSession(jsonEncode(session.toJson()));
          if (session.isExpired) {
            await _refresh(session, allowed);
          }
          if (!allowed()) throw SyncCancelled();
          await action();
        } finally {
          _transport.close();
        }
      },
      wait: headless ? Duration.zero : _foregroundWait,
      active: allowed,
    );
  }

  Future<void> _refresh(Session session, bool Function() allowed) async {
    final token = session.refreshToken;
    if (token == null || token.isEmpty) {
      if (!headless) _setAccount(null);
      throw SyncCancelled();
    }
    final Session refreshed;
    try {
      final result = await _auth.refreshSession(token);
      refreshed = result.session!;
    } on AuthApiException catch (error) {
      if (allowed() && ['400', '401', '403'].contains(error.statusCode)) {
        await storage.removePersistedSession();
        _setAccount(null);
      }
      rethrow;
    }
    if (refreshed.user.id != session.user.id ||
        !_matchesToken(refreshed) ||
        refreshed.isExpired) {
      throw SyncCancelled();
    }
    // Keep a rotated token even if the pass was stopped. Sign-out waits on
    // the same gate and removes the session after this write
    await storage.persistSession(jsonEncode(refreshed.toJson()));
  }

  void abortRequests() => _transport.close();

  Future<void> dispose() async {
    abortRequests();
    _auth.dispose();
    await _cloud.dispose();
    await _changes.close();
  }
}

class _SyncTransport extends BaseClient {
  final Client Function()? _createClient;
  Client? _client;
  bool Function()? _active;

  _SyncTransport(this._createClient);

  void start(bool Function() active) {
    _active = active;
    _client =
        _createClient?.call() ??
        IOClient(
          HttpClient()..connectionTimeout = AndroidSyncSession._requestTimeout,
        );
  }

  @override
  Future<StreamedResponse> send(BaseRequest request) async {
    final client = _client;
    if (client == null || !_active!()) throw SyncCancelled();
    final response = await client
        .send(request)
        .timeout(
          AndroidSyncSession._requestTimeout,
          onTimeout: () {
            client.close();
            throw TimeoutException('Cloud request timed out');
          },
        );
    return StreamedResponse(
      response.stream.timeout(AndroidSyncSession._requestTimeout),
      response.statusCode,
      contentLength: response.contentLength,
      headers: response.headers,
      request: response.request ?? request,
      reasonPhrase: response.reasonPhrase,
    );
  }

  @override
  void close() {
    _client?.close();
    _client = null;
    _active = null;
  }
}
