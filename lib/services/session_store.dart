import 'dart:convert';
import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

abstract interface class SessionVault {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class SecureSessionVault implements SessionVault {
  final FlutterSecureStorage _storage;
  SecureSessionVault([FlutterSecureStorage? storage])
    : _storage = storage ?? const FlutterSecureStorage();
  @override
  Future<String?> read(String key) => _storage.read(key: key);
  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);
  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

class SessionStore extends ChangeNotifier {
  static const credentialKey = 'pulso_v2_credential';
  static const pendingKey = 'pulso_v2_pending_email';
  static const purchaseIntentsKey = 'pulso_v2_purchase_intents';
  static const transferIntentsKey = 'pulso_v2_ticket_transfer_intents';
  final SessionVault vault;
  String? _token;
  String? expiresAt;
  Map<String, dynamic>? _user;
  String pendingEmail = '';
  bool _validated = false;
  bool _locked = false;
  bool _loaded = false;
  Future<void> _intentQueue = Future.value();
  Future<void> _transferIntentQueue = Future.value();

  SessionStore({SessionVault? vault}) : vault = vault ?? SecureSessionVault();
  String? get token => _token;
  bool get hasCredential => _token != null;
  bool get locked => _locked && _token != null;
  bool get authenticated =>
      !_locked &&
      _validated &&
      _token != null &&
      _user?['email_verified'] == true;
  Map<String, dynamic>? get user =>
      authenticated ? Map.unmodifiable(_user!) : null;
  String get email => (user?['email'] ?? pendingEmail).toString();

  Future<void> load() async {
    if (_loaded) return;
    // Remove the obsolete external-payment return hint on upgrade.
    await vault.delete('pulso_v2_pending_checkout');
    pendingEmail = (await vault.read(pendingKey) ?? '').trim();
    final raw = await vault.read(credentialKey);
    _loaded = true;
    if (raw == null) return;
    try {
      final value = jsonDecode(raw) as Map<String, dynamic>;
      final token = value['access_token'];
      final expiration = value['expires_at'];
      if (token is! String ||
          token.isEmpty ||
          expiration is! String ||
          DateTime.tryParse(expiration) == null) {
        throw const FormatException('Invalid stored session');
      }
      _token = token;
      expiresAt = expiration;
      // A cached ID/profile never authorizes the UI; me.php must validate first.
      _validated = false;
    } catch (_) {
      await clear();
    }
  }

  bool _validUser(Map<String, dynamic> user) =>
      user['email_verified'] == true &&
      int.tryParse('${user['id']}') != null &&
      int.parse('${user['id']}') > 0;

  Future<void> acceptLogin(Map<String, dynamic> envelope) async {
    final rawUser = envelope['user'];
    final token = envelope['access_token'];
    final expiration = envelope['expires_at'];
    if (rawUser is! Map ||
        !_validUser(Map<String, dynamic>.from(rawUser)) ||
        token is! String ||
        token.isEmpty ||
        expiration is! String ||
        DateTime.tryParse(expiration) == null) {
      throw const FormatException('La sesión recibida no es válida.');
    }
    await vault.write(
      credentialKey,
      jsonEncode({'access_token': token, 'expires_at': expiration}),
    );
    await vault.delete(pendingKey);
    _loaded = true;
    _token = token;
    expiresAt = expiration;
    _user = Map<String, dynamic>.from(rawUser);
    pendingEmail = '';
    _validated = true;
    _locked = false;
    notifyListeners();
  }

  void acceptValidatedUser(Map<String, dynamic> user, {bool unlock = false}) {
    if (_token == null || !_validUser(user)) {
      throw const FormatException('No se pudo validar la sesión guardada.');
    }
    _user = Map.from(user);
    _validated = true;
    _locked = !unlock;
    notifyListeners();
  }

  void lock() {
    if (!_validated || _token == null) return;
    _locked = true;
    notifyListeners();
  }

  Future<void> pending(String email) async {
    await clear();
    pendingEmail = email.trim();
    await vault.write(pendingKey, pendingEmail);
    notifyListeners();
  }

  Future<void> clearPending() async {
    pendingEmail = '';
    await vault.delete(pendingKey);
    notifyListeners();
  }

  Future<T> _serialIntent<T>(Future<T> Function() operation) {
    final result = Completer<T>();
    _intentQueue = _intentQueue.then((_) async {
      try {
        result.complete(await operation());
      } catch (e, stack) {
        result.completeError(e, stack);
      }
    });
    return result.future;
  }

  Future<T> withTransferIntents<T>(Future<T> Function() operation) {
    final result = Completer<T>();
    _transferIntentQueue = _transferIntentQueue.then((_) async {
      try {
        result.complete(await operation());
      } catch (error, stack) {
        result.completeError(error, stack);
      }
    });
    return result.future;
  }

  String _intentKey(int eventId, int qty) {
    if (!authenticated) throw StateError('Ingresá para crear una compra.');
    return '${_user!['id']}:$eventId:$qty';
  }

  Future<Map<String, dynamic>> _readIntents() async {
    final raw = await vault.read(purchaseIntentsKey);
    if (raw == null) return {};
    // Fail closed on corrupted persistence; do not silently replace an attempt
    // that may already have committed on the server.
    final value = jsonDecode(raw);
    if (value is! Map) {
      throw const FormatException('No se pudo recuperar el intento de compra.');
    }
    return Map<String, dynamic>.from(value);
  }

  Future<String> beginPurchaseIntent(int eventId, int qty) {
    final key = _intentKey(eventId, qty);
    return _serialIntent(() async {
      final intents = await _readIntents();
      final existing = intents[key];
      if (existing is String && existing.isNotEmpty) return existing;
      final random = Random.secure();
      final bytes = List.generate(16, (_) => random.nextInt(256));
      bytes[6] = (bytes[6] & 15) | 64;
      bytes[8] = (bytes[8] & 63) | 128;
      final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      final id =
          '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
      intents[key] = id;
      await vault.write(purchaseIntentsKey, jsonEncode(intents));
      return id;
    });
  }

  Future<void> completePurchaseIntent(int eventId, int qty, String requestId) {
    final key = _intentKey(eventId, qty);
    return _serialIntent(() async {
      final intents = await _readIntents();
      if (intents[key] == requestId) intents.remove(key);
      await vault.write(purchaseIntentsKey, jsonEncode(intents));
    });
  }

  Future<void> clear() async {
    _token = null;
    expiresAt = null;
    _user = null;
    _validated = false;
    _locked = false;
    _loaded = true;
    pendingEmail = '';
    notifyListeners();
    await vault.delete(credentialKey);
    await vault.delete(pendingKey);
    await vault.delete('pulso_v2_pending_checkout');
    // Serialize erasure after any in-flight transfer write so logout cannot
    // leave recipient emails behind when a native secure-storage call ends.
    await withTransferIntents(() => vault.delete(transferIntentsKey));
  }
}
