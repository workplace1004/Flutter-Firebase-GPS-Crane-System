import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:grua_core/grua_core.dart';

import '../../router.dart';
import 'registration_controller.dart';

/// Dominican mobile prefixes. Numbers here are +1 with one of these area
/// codes, so validating on them catches the common typo of a missing digit
/// before we spend an SMS on it.
const _doAreaCodes = {'809', '829', '849'};

class PhoneScreen extends ConsumerStatefulWidget {
  const PhoneScreen({super.key});

  @override
  ConsumerState<PhoneScreen> createState() => _PhoneScreenState();
}

class _PhoneScreenState extends ConsumerState<PhoneScreen> {
  final _controller = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  var _sending = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  String get _digits => _controller.text.replaceAll(RegExp(r'\D'), '');

  bool get _isValid =>
      _digits.length == 10 && _doAreaCodes.contains(_digits.substring(0, 3));

  Future<void> _submit() async {
    if (!_isValid || _sending) return;
    setState(() {
      _sending = true;
      _error = null;
    });

    // A plain sign-in. Answers left by a registration the customer abandoned
    // would otherwise be written onto whichever account signs in here.
    ref.read(registrationControllerProvider.notifier).clear();

    final e164 = '+1$_digits';
    final result =
        await ref.read(authRepositoryProvider).startPhoneVerification(e164);
    if (!mounted) return;

    switch (result) {
      // Android verified the number without a code; the router moves on.
      case Ok(value: AuthRepository.phoneSignedIn):
        break;
      case Ok(value: final verificationId):
        unawaited(
          context.push(
            '${Routes.otp}?vid=$verificationId'
            '&phone=${Uri.encodeComponent(e164)}',
          ),
        );
      case Err(:final failure):
        _error = failure.userMessage;
    }
    setState(() => _sending = false);
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: () => context.pop()),
      ),
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: LayoutBuilder(
            builder: (context, constraints) {
              // Scrolls when the keyboard leaves no room; otherwise the Spacer
              // pushes the call to action down to the bottom edge, where the
              // thumb already is.
              return SingleChildScrollView(
                padding: const EdgeInsets.symmetric(
                  horizontal: Insets.gutter,
                  vertical: Insets.xl,
                ),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    minHeight: constraints.maxHeight - Insets.xl * 2,
                  ),
                  child: IntrinsicHeight(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Center(child: GruaLogo(size: 180)),
                        const SizedBox(height: Insets.xl),
                        Text('¿Cuál es tu número?', style: text.headlineMedium),
                        const SizedBox(height: Insets.sm),
                        Text(
                          'Te enviaremos un código por SMS para confirmar que '
                          'eres tú.',
                          style: text.bodyLarge
                              ?.copyWith(color: BrandColors.grey600),
                        ),
                        const SizedBox(height: Insets.xxxl),
                        const FieldLabel('Número de teléfono'),
                        const SizedBox(height: Insets.sm),
                        TextFormField(
                          controller: _controller,
                          autofocus: true,
                          keyboardType: TextInputType.phone,
                          textInputAction: TextInputAction.done,
                          onChanged: (_) => setState(() => _error = null),
                          onFieldSubmitted: (_) => _submit(),
                          inputFormatters: [
                            FilteringTextInputFormatter.digitsOnly,
                            LengthLimitingTextInputFormatter(10),
                            _DoPhoneFormatter(),
                          ],
                          style: text.headlineSmall,
                          decoration: const InputDecoration(
                            prefixText: '+1  ',
                            hintText: '809-555-1234',
                          ),
                        ),
                        const SizedBox(height: Insets.sm),
                        Text(
                          'Solo aceptamos números dominicanos (809, 829 y 849).',
                          style: text.bodySmall
                              ?.copyWith(color: BrandColors.grey600),
                        ),

                        if (_error != null) ...[
                          const SizedBox(height: Insets.lg),
                          InlineNotice(
                            message: _error!,
                            tone: NoticeTone.error,
                          ),
                        ],

                        // The form stays at the top, the button group sits on
                        // the bottom edge.
                        const Spacer(),
                        const SizedBox(height: Insets.xl),

                        ElevatedButton(
                          onPressed: _isValid && !_sending ? _submit : null,
                          child: _sending
                              ? const SizedBox(
                                  width: 22,
                                  height: 22,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2.4,
                                    color: BrandColors.white,
                                  ),
                                )
                              : const Text('Enviar código'),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

/// Formats as `809-555-1234` while keeping the raw digits in the model.
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
