import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:pulso_libre_app/services/api_config.dart';
import 'package:pulso_libre_app/services/session_store.dart';
import 'package:pulso_libre_app/services/qr_controller.dart';

class MemoryVault implements SessionVault {
  final Map<String, String> values = {};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

class ManualClock implements MonotonicClock {
  Duration value = Duration.zero;
  @override
  Duration get now => value;
  void advance(Duration duration) {
    value += duration;
  }
}

ApiConfig localConfig() => ApiConfig(
  base: Uri.parse('http://127.0.0.1:18765/api/pulso_libre'),
  localTest: true,
);
const buyer = {
  'id': 9001,
  'email': 'buyer@example.invalid',
  'name': 'Synthetic Buyer',
  'email_verified': true,
};
const loginEnvelope = {
  'ok': true,
  'user': buyer,
  'access_token': 'SYNTHETIC_TOKEN_ONLY',
  'expires_at': '2035-01-01T00:00:00Z',
};
Future<SessionStore> signedSession([MemoryVault? vault]) async {
  final session = SessionStore(vault: vault ?? MemoryVault());
  await session.acceptLogin(loginEnvelope);
  return session;
}

http.Response response(int status, Map<String, dynamic> data) => http.Response(
  jsonEncode(data),
  status,
  headers: {'content-type': 'application/json'},
);
Map<String, dynamic> event(int id, String title) => {
  'id': id,
  'title': title,
  'status': 'active',
  'date_event': '2030-06-10 20:00:00',
  'location': 'Prueba local',
  'price_from': 100,
  'sale_mode': 'receipt_manual',
  'stock_available': 50,
  'max_per_user': 4,
};
Map<String, dynamic> catalog() => {
  'ok': true,
  'items': [event(101, 'ROJO'), event(202, 'AZUL')],
  'upcoming_events': [event(202, 'AZUL'), event(101, 'ROJO')],
  'featured_event_id': 202,
};
Widget fakeImage(Uri uri, BoxFit fit) =>
    SizedBox(height: 80, child: Text('image:${uri.path}'));
