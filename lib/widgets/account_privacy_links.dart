import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'brand_style.dart';

class AccountPrivacyLinks extends StatelessWidget {
  final Future<bool> Function(Uri)? externalLauncher;

  const AccountPrivacyLinks({super.key, this.externalLauncher});

  Future<void> _open(BuildContext context, String path) async {
    final uri = Uri.https('pllabs.com.ar', '/pulso-libre/$path/');
    try {
      final opened =
          await (externalLauncher?.call(uri) ??
              launchUrl(uri, mode: LaunchMode.externalApplication));
      if (opened) return;
    } catch (_) {
      // Keep the public resource available when Android cannot open a browser.
    }
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('No se pudo abrir la página'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Copiá este enlace y abrilo en tu navegador:'),
              const SizedBox(height: 12),
              SelectableText(uri.toString()),
              const SizedBox(height: 12),
              const Text(
                'Abrir la página no envía una solicitud ni elimina datos.',
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Entendido'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text('Tus datos', style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 8),
      const Text('Conocé cómo usamos tus datos y cómo pedir su eliminación.'),
      const SizedBox(height: 12),
      OutlinedButton(
        key: const ValueKey('account-privacy'),
        onPressed: () => _open(context, 'privacidad'),
        child: const Text(
          'Política de privacidad',
          textAlign: TextAlign.center,
        ),
      ),
      const SizedBox(height: 8),
      OutlinedButton(
        key: const ValueKey('account-deletion'),
        onPressed: () => _open(context, 'eliminar-cuenta'),
        child: const Text(
          'Solicitar eliminación de cuenta',
          textAlign: TextAlign.center,
        ),
      ),
      const SizedBox(height: 8),
      const Text(
        'La solicitud se gestiona por correo. Abrir el enlace no borra tu '
        'cuenta ni envía la solicitud. Cerrar sesión tampoco elimina tus datos.',
        style: TextStyle(color: brandMuted),
      ),
    ],
  );
}
