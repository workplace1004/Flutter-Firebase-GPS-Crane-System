import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:grua_core/grua_core.dart';

import '../../router.dart';
import 'registration_controller.dart';

/// Dominican mobile prefixes, the same rule the sign-in screen applies.
const _doAreaCodes = {'809', '829', '849'};

/// Everything we ask a new customer for, in one screen.
///
/// The order is deliberate: name and phone are the two a chofer cannot arrive
/// without, so they come first and are the only required fields. Email,
/// address and the car save typing later and are all skippable, because
/// somebody signing up beside a broken-down car will not fill in a long form.
///
/// Nothing here is written on submit. Firebase has no account until the SMS
/// code is confirmed, so the answers are held by the registration controller
/// and applied on the far side of the OTP screen.
class RegisterScreen extends ConsumerStatefulWidget {
  const RegisterScreen({super.key});

  @override
  ConsumerState<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends ConsumerState<RegisterScreen> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _email = TextEditingController();
  final _address = TextEditingController();
  final _make = TextEditingController();
  final _model = TextEditingController();
  final _plate = TextEditingController();

  var _sending = false;
  String? _error;

  @override
  void dispose() {
    for (final controller in [
      _name,
      _phone,
      _email,
      _address,
      _make,
      _model,
      _plate,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  String get _digits => _phone.text.replaceAll(RegExp(r'\D'), '');

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false) || _sending) return;

    setState(() {
      _sending = true;
      _error = null;
    });

    ref.read(registrationControllerProvider.notifier).remember(
          name: _name.text.trim(),
          email: _email.text.trim(),
          address: _address.text.trim(),
          make: _make.text.trim(),
          model: _model.text.trim(),
          plate: _plate.text.trim().toUpperCase(),
        );

    final e164 = '+1$_digits';
    final result =
        await ref.read(authRepositoryProvider).startPhoneVerification(e164);
    if (!mounted) return;

    switch (result) {
      // Android verified the number without a code: signed in already, and the
      // app root writes the held answers.
      case Ok(value: AuthRepository.phoneSignedIn):
        setState(() => _sending = false);
      case Ok(value: final verificationId):
        setState(() => _sending = false);
        unawaited(
          context.push(
            '${Routes.otp}?vid=$verificationId'
            '&phone=${Uri.encodeComponent(e164)}',
          ),
        );
      // The answers stay held: nobody should retype the form to retry an SMS
      // that failed to send.
      case Err(:final failure):
        setState(() {
          _sending = false;
          _error = failure.userMessage;
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;

    return Scaffold(
      backgroundColor: BrandColors.white,
      appBar: AppBar(leading: BackButton(onPressed: () => context.pop())),
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: Insets.gutter),
            children: [
              const Center(child: GruaLogo(size: 180)),
              const SizedBox(height: Insets.xl),
              Text('Crear tu cuenta', style: text.headlineMedium),
              const SizedBox(height: Insets.sm),
              Text(
                'Solo el nombre y el teléfono son obligatorios. El resto lo '
                'puedes completar después.',
                style: text.bodyLarge?.copyWith(color: BrandColors.grey600),
              ),
              const SizedBox(height: Insets.xxl),

              const FieldLabel('Nombre completo *'),
              const SizedBox(height: Insets.sm),
              TextFormField(
                controller: _name,
                textCapitalization: TextCapitalization.words,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(hintText: 'Ramón Peña'),
                validator: (value) => (value?.trim().length ?? 0) < 3
                    ? 'Escribe tu nombre completo.'
                    : null,
              ),
              const SizedBox(height: Insets.xl),

              const FieldLabel('Teléfono / WhatsApp *'),
              const SizedBox(height: Insets.sm),
              TextFormField(
                controller: _phone,
                keyboardType: TextInputType.phone,
                textInputAction: TextInputAction.next,
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(10),
                  _DoPhoneFormatter(),
                ],
                decoration: const InputDecoration(
                  prefixText: '+1  ',
                  hintText: '809-555-1234',
                ),
                validator: (_) {
                  final digits = _digits;
                  if (digits.length != 10) {
                    return 'El número debe tener 10 dígitos.';
                  }
                  if (!_doAreaCodes.contains(digits.substring(0, 3))) {
                    return 'Solo aceptamos 809, 829 y 849.';
                  }
                  return null;
                },
              ),
              const SizedBox(height: Insets.xs),
              Text(
                'Te enviaremos un código por SMS a este número.',
                style: text.bodySmall?.copyWith(color: BrandColors.grey600),
              ),
              const SizedBox(height: Insets.xl),

              const FieldLabel('Correo electrónico'),
              const SizedBox(height: Insets.sm),
              TextFormField(
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(
                  hintText: 'Para recibir tus facturas',
                ),
                validator: (value) {
                  final trimmed = value?.trim() ?? '';
                  if (trimmed.isEmpty) return null;
                  final valid =
                      RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(trimmed);
                  return valid ? null : 'Ese correo no parece válido.';
                },
              ),
              const SizedBox(height: Insets.xl),

              const FieldLabel('Dirección principal'),
              const SizedBox(height: Insets.sm),
              TextFormField(
                controller: _address,
                textCapitalization: TextCapitalization.sentences,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(
                  hintText: 'Av. 27 de Febrero 123, Santo Domingo',
                ),
              ),
              const SizedBox(height: Insets.xxl),

              Text('Agregar vehículo', style: text.titleMedium),
              const SizedBox(height: Insets.xs),
              Text(
                'Opcional. Lo usamos para llenar tu próxima solicitud.',
                style: text.bodySmall?.copyWith(color: BrandColors.grey600),
              ),
              const SizedBox(height: Insets.lg),
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _make,
                      textCapitalization: TextCapitalization.words,
                      textInputAction: TextInputAction.next,
                      decoration: const InputDecoration(hintText: 'Marca'),
                    ),
                  ),
                  const SizedBox(width: Insets.md),
                  Expanded(
                    child: TextFormField(
                      controller: _model,
                      textCapitalization: TextCapitalization.words,
                      textInputAction: TextInputAction.next,
                      decoration: const InputDecoration(hintText: 'Modelo'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: Insets.md),
              TextFormField(
                controller: _plate,
                textCapitalization: TextCapitalization.characters,
                textInputAction: TextInputAction.done,
                onFieldSubmitted: (_) => _submit(),
                decoration: const InputDecoration(hintText: 'Placa'),
              ),

              if (_error != null) ...[
                const SizedBox(height: Insets.lg),
                InlineNotice(message: _error!, tone: NoticeTone.error),
              ],
              const SizedBox(height: Insets.xxl),
              ElevatedButton(
                onPressed: _sending ? null : _submit,
                child: _sending
                    ? const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.4,
                          color: BrandColors.white,
                        ),
                      )
                    : const Text('Crear cuenta'),
              ),
              const SizedBox(height: Insets.lg),
              Center(
                child: TextButton(
                  onPressed: () => context.push(Routes.phone),
                  child: const Text('Ya tengo cuenta'),
                ),
              ),
              const SizedBox(height: Insets.xl),
            ],
          ),
        ),
      ),
    );
  }
}

/// Formats as `809-555-1234` while the raw digits stay the source of truth.
class _DoPhoneFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final digits = newValue.text.replaceAll(RegExp(r'\D'), '');
    final buffer = StringBuffer();
    for (var i = 0; i < digits.length; i++) {
      if (i == 3 || i == 6) buffer.write('-');
      buffer.write(digits[i]);
    }
    final formatted = buffer.toString();
    return TextEditingValue(
      text: formatted,
      selection: TextSelection.collapsed(offset: formatted.length),
    );
  }
}
