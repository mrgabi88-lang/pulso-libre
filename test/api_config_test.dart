import 'package:flutter_test/flutter_test.dart';
import 'package:pulso_libre_app/services/api_config.dart';

void main() {
  final production = ApiConfig(
    base: Uri.parse('https://pllabs.com.ar/api/pulso_libre'),
    localTest: false,
  );

  test('compiled environment uses production unless local tests opt in', () {
    final config = ApiConfig.environment();
    const localOptIn = bool.fromEnvironment('PULSO_LOCAL_TEST');
    expect(config.localTest, localOptIn);
    expect(
      config.base.toString(),
      localOptIn
          ? 'http://127.0.0.1:18765/api/pulso_libre'
          : 'https://pllabs.com.ar/api/pulso_libre',
    );
  });

  test('production API accepts only the fixed HTTPS origin and API path', () {
    for (final value in [
      'http://pllabs.com.ar/api/pulso_libre',
      'https://www.pllabs.com.ar/api/pulso_libre',
      'https://pllabs.com.ar.evil.invalid/api/pulso_libre',
      'https://other.invalid/api/pulso_libre',
      'https://pllabs.com.ar:8443/api/pulso_libre',
      'https://pllabs.com.ar/other-api',
      'https://synthetic@pllabs.com.ar/api/pulso_libre',
      'https://pllabs.com.ar/api/pulso_libre?environment=local',
      'https://pllabs.com.ar/api/pulso_libre#local',
      'http://127.0.0.1:18765/api/pulso_libre',
      'https://localhost/api/pulso_libre',
    ]) {
      expect(
        () => ApiConfig(base: Uri.parse(value), localTest: false),
        throwsStateError,
        reason: value,
      );
    }
    final normalized = ApiConfig(
      base: Uri.parse('https://pllabs.com.ar:443/api/pulso_libre/'),
      localTest: false,
    );
    expect(
      normalized.endpoint('purchase_get.php', {'order_id': '77'}).toString(),
      'https://pllabs.com.ar/api/pulso_libre/purchase_get.php?order_id=77',
    );
  });

  test('local mode cannot connect its test identity to a production API', () {
    for (final value in [
      'https://pllabs.com.ar/api/pulso_libre',
      'http://other.invalid/api/pulso_libre',
      'file:///api/pulso_libre',
      'http://synthetic@127.0.0.1:18765/api/pulso_libre',
    ]) {
      expect(
        () => ApiConfig(base: Uri.parse(value), localTest: true),
        throwsStateError,
        reason: value,
      );
    }
    for (final host in ['127.0.0.1', 'localhost', '10.0.2.2', '[::1]']) {
      expect(
        ApiConfig(
          base: Uri.parse('http://$host:18765/api/pulso_libre'),
          localTest: true,
        ).localTest,
        isTrue,
      );
    }
  });

  test('production resources never downgrade to HTTP or loopback', () {
    for (final value in [
      'http://pllabs.com.ar/assets/flyer.png',
      // Explicit port 443 must not make HTTP share the HTTPS authority.
      'http://pllabs.com.ar:443/assets/audio.wav',
      'http://127.0.0.1:18765/assets/audio.wav',
      'https://127.0.0.1/assets/flyer.png',
      'https://localhost/assets/flyer.png',
      '//10.0.2.2/assets/audio.wav',
      'https://synthetic@pllabs.com.ar/assets/flyer.png',
      'file:///assets/flyer.png',
    ]) {
      expect(production.mediaUri(value), isNull, reason: value);
      expect(production.mediaUri(value, external: true), isNull, reason: value);
    }
    expect(
      production.mediaUri('/assets/pulso_libre/flyer.png').toString(),
      'https://pllabs.com.ar/assets/pulso_libre/flyer.png',
    );
    expect(
      production.mediaUri('https://cdn.example.invalid/flyer.png'),
      isNotNull,
    );
    expect(
      production.mediaUri(
        'https://soundcloud.com/artist/track',
        external: true,
      ),
      isNotNull,
    );
  });

  test('local uploaded resources keep only their own HTTP authority', () {
    final local = ApiConfig(
      base: Uri.parse('http://127.0.0.1:18765/api/pulso_libre'),
      localTest: true,
    );
    expect(
      local.mediaUri('/assets/audio.wav').toString(),
      'http://127.0.0.1:18765/assets/audio.wav',
    );
    expect(local.mediaUri('http://127.0.0.1:18766/audio.wav'), isNull);
    expect(local.mediaUri('http://pllabs.com.ar/audio.wav'), isNull);
    expect(local.mediaUri('/assets/audio.wav', external: true), isNull);
  });
}
