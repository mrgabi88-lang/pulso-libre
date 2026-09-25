import 'dart:async';
import 'package:flutter/material.dart';
import '../models/event.dart';
import '../services/api_service.dart';
import 'brand_style.dart';

const passwordRecoveryAcceptedMessage =
    'Si el correo corresponde a una cuenta habilitada, recibirás un enlace '
    'para elegir una contraseña nueva.';

class PasswordRecoveryButton extends StatefulWidget {
  final ApiService api;
  final String Function() initialEmail;
  final bool signedIn;
  final bool enabled;

  const PasswordRecoveryButton({
    super.key,
    required this.api,
    required this.initialEmail,
    this.signedIn = false,
    this.enabled = true,
  });

  @override
  State<PasswordRecoveryButton> createState() => _PasswordRecoveryButtonState();
}

class _PasswordRecoveryButtonState extends State<PasswordRecoveryButton> {
  // Keep pending requests and cooldowns when the dialog is closed and reopened.
  late final _request = _PasswordRecoveryRequest(widget.api);
  DialogRoute<void>? _dialogRoute;

  Future<void> _open() async {
    if (_dialogRoute != null) return;
    final route = DialogRoute<void>(
      context: context,
      builder: (context) => _PasswordRecoveryDialog(
        request: _request,
        initialEmail: widget.initialEmail(),
      ),
    );
    _dialogRoute = route;
    try {
      await Navigator.of(context).push(route);
    } finally {
      _dialogRoute = null;
    }
  }

  @override
  void dispose() {
    final route = _dialogRoute;
    final navigator = route?.navigator;
    // Account disposal can mean the app just locked. Do not leave its email
    // visible in a dialog above the lock screen or retain an unusable form.
    if (route != null && navigator != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (navigator.mounted && route.isActive) navigator.removeRoute(route);
      });
    }
    _request.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TextButton(
    key: const ValueKey('account-password-recovery'),
    onPressed: widget.enabled ? _open : null,
    child: Text(
      widget.signedIn
          ? 'Cambiar contraseña por correo'
          : 'Olvidé mi contraseña',
      textAlign: TextAlign.center,
    ),
  );
}

class _PasswordRecoveryRequest extends ChangeNotifier {
  final ApiService api;
  bool busy = false;
  bool accepted = false;
  bool _disposed = false;
  String? error;
  String? requestedEmail;
  int cooldown = 0;
  Timer? _timer;

  _PasswordRecoveryRequest(this.api);

  void _startCooldown(int seconds) {
    _timer?.cancel();
    cooldown = seconds > 0 ? seconds : 0;
    if (seconds <= 0) return;
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_disposed) return;
      cooldown = (seconds - timer.tick).clamp(0, seconds);
      if (cooldown == 0) timer.cancel();
      notifyListeners();
    });
  }

  Future<void> submit(String email) async {
    if (_disposed || busy || cooldown > 0) return;
    busy = true;
    accepted = false;
    error = null;
    requestedEmail = email;
    notifyListeners();
    try {
      final result = await api.requestPasswordReset(email);
      if (_disposed) return;
      accepted = true;
      final retry = integer(result['retry_after']);
      _startCooldown(retry > 0 ? retry : 60);
    } on ApiException catch (e) {
      if (_disposed) return;
      error = e.message;
      _startCooldown(e.retryAfter ?? (e.statusCode == 429 ? 60 : 0));
    } catch (_) {
      if (_disposed) return;
      error = 'No pudimos solicitar el enlace. Intentá nuevamente.';
    } finally {
      if (!_disposed) {
        busy = false;
        notifyListeners();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}

class _PasswordRecoveryDialog extends StatefulWidget {
  final _PasswordRecoveryRequest request;
  final String initialEmail;

  const _PasswordRecoveryDialog({
    required this.request,
    required this.initialEmail,
  });

  @override
  State<_PasswordRecoveryDialog> createState() =>
      _PasswordRecoveryDialogState();
}

class _PasswordRecoveryDialogState extends State<_PasswordRecoveryDialog> {
  final _form = GlobalKey<FormState>();
  late final _email = TextEditingController(
    text: widget.request.requestedEmail ?? widget.initialEmail.trim(),
  );

  void _submit() {
    if (_form.currentState?.validate() != true) return;
    FocusScope.of(context).unfocus();
    widget.request.submit(_email.text.trim());
  }

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.request,
    builder: (context, child) {
      final request = widget.request;
      final blocked = request.busy || request.cooldown > 0;
      return AlertDialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
        title: const Text('Recuperar contraseña'),
        scrollable: true,
        content: Form(
          key: _form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Ingresá el correo de tu cuenta. El enlace te permitirá '
                'elegir una contraseña nueva en el navegador.',
              ),
              const SizedBox(height: 16),
              TextFormField(
                key: const ValueKey('password-recovery-email'),
                controller: _email,
                enabled: !blocked,
                keyboardType: TextInputType.emailAddress,
                textInputAction: TextInputAction.done,
                autofillHints: const [AutofillHints.email],
                autocorrect: false,
                enableSuggestions: false,
                decoration: const InputDecoration(
                  labelText: 'Correo electrónico',
                  errorMaxLines: 3,
                ),
                validator: (value) {
                  final email = value?.trim() ?? '';
                  if (email.length > 254 ||
                      !RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(email)) {
                    return 'Ingresá un correo electrónico válido.';
                  }
                  return null;
                },
                onFieldSubmitted: (_) {
                  if (!blocked) _submit();
                },
              ),
              const SizedBox(height: 16),
              FilledButton(
                key: const ValueKey('password-recovery-send'),
                onPressed: blocked ? null : _submit,
                child: Text(
                  request.busy
                      ? 'Solicitando enlace…'
                      : request.cooldown > 0
                      ? 'Reintentar en ${request.cooldown}s'
                      : 'Solicitar enlace',
                  textAlign: TextAlign.center,
                ),
              ),
              if (request.accepted || request.error != null) ...[
                const SizedBox(height: 16),
                Semantics(
                  liveRegion: true,
                  child: Text(
                    request.error ?? passwordRecoveryAcceptedMessage,
                    key: const ValueKey('password-recovery-result'),
                  ),
                ),
              ],
              const SizedBox(height: 16),
              const Text(
                'Solicitar el enlace no cambia tu contraseña ni cierra tu '
                'sesión. Cuando elijas la nueva contraseña, volvé a la app '
                'e ingresá con ella.',
                style: TextStyle(color: brandMuted),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            key: const ValueKey('password-recovery-close'),
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cerrar'),
          ),
        ],
      );
    },
  );
}
