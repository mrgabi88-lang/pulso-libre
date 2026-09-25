class ApiConfig {
  static const productionBaseUrl = 'https://pllabs.com.ar/api/pulso_libre';
  static const localBaseUrl = 'http://127.0.0.1:18765/api/pulso_libre';
  static const _localHosts = {'127.0.0.1', 'localhost', '::1', '10.0.2.2'};
  static const _environmentLocalTest = bool.fromEnvironment('PULSO_LOCAL_TEST');
  final Uri base;
  final bool localTest;
  ApiConfig({required Uri base, required this.localTest})
    : base = _validate(base, localTest);

  factory ApiConfig.environment() => ApiConfig(
    base: Uri.parse(
      const String.fromEnvironment(
        'PULSO_API_BASE_URL',
        defaultValue: _environmentLocalTest ? localBaseUrl : productionBaseUrl,
      ),
    ),
    localTest: _environmentLocalTest,
  );

  static Uri _validate(Uri uri, bool localTest) {
    if (uri.userInfo.isNotEmpty || uri.hasQuery || uri.hasFragment) {
      throw StateError('La dirección del servidor no es válida.');
    }
    final normalized = uri.replace(
      path: uri.path.replaceFirst(RegExp(r'/+$'), ''),
    );
    if (localTest) {
      if (_localHosts.contains(uri.host) &&
          {'http', 'https'}.contains(uri.scheme)) {
        return normalized;
      }
      throw StateError(
        'Esta versión de pruebas solo puede conectarse al servidor local.',
      );
    }
    if (uri.scheme != 'https' ||
        uri.host != 'pllabs.com.ar' ||
        uri.port != 443 ||
        normalized.path != '/api/pulso_libre') {
      throw StateError(
        'Esta versión solo puede conectarse a Pulso Libre por HTTPS.',
      );
    }
    return normalized;
  }

  Uri endpoint(String name, [Map<String, String>? query]) =>
      base.replace(path: '${base.path}/$name', queryParameters: query);

  Uri? mediaUri(String? raw, {bool external = false}) {
    if (raw == null || raw.trim().isEmpty) return null;
    final parsed = Uri.tryParse(raw.trim());
    if (parsed == null) return null;
    final uri = parsed.hasScheme ? parsed : base.resolve(raw.trim());
    if (uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        !localTest && _localHosts.contains(uri.host) ||
        uri.hasFragment && !external) {
      return null;
    }
    if (uri.scheme == 'https') return uri;
    if (localTest &&
        !external &&
        uri.scheme == 'http' &&
        uri.host == base.host &&
        uri.port == base.port) {
      return uri;
    }
    return null;
  }
}
