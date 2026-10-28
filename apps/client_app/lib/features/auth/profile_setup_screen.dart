import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:grua_core/grua_core.dart';

/// Collects the name a chofer will ask for on arrival.
///
/// This is not optional politeness: the chofer pulls up to a broken-down car on
/// a highway shoulder and needs someone to call for. The RNC field is optional
/// and only matters for a customer who wants a crédito fiscal receipt.
class ProfileSetupScreen extends ConsumerStatefulWidget {
  const ProfileSetupScreen({super.key});

  @override
  ConsumerState<ProfileSetupScreen> createState() => _ProfileSetupScreenState();
}

class _ProfileSetupScreenState extends ConsumerState<ProfileSetupScreen> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _rnc = TextEditingController();

  var _saving = false;
  var _wantsFiscalReceipt = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _rnc.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false) || _saving) return;
    final uid = ref.read(currentUserIdProvider);
    if (uid == null) return;

    setState(() {
      _saving = true;
      _error = null;
    });

    // The document may still be missing if creating it failed after sign-in,
    // and the update below cannot create it. Idempotent when it exists.
    final created = await ref.read(functionsGatewayProvider).ensureProfile();
    if (!mounted) return;
    if (created case Err(:final failure)) {
      setState(() {
        _saving = false;
        _error = failure.userMessage;
      });
      return;
    }

    final result = await ref.read(userRepositoryProvider).updateProfile(
          uid,
          name: _name.text.trim(),
          email: _email.text.trim(),
          rnc: _wantsFiscalReceipt ? _rnc.text.trim() : '',
        );
    if (!mounted) return;

    result.fold(
      // The router redirects home as soon as the profile stream reports a name.
      (_) => setState(() => _saving = false),
      (failure) => setState(() {
        _saving = false;
        _error = failure.userMessage;
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(title: const GruaLogo(size: 74)),
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: Insets.gutter),
            children: [
              const SizedBox(height: Insets.xl),
              Text('¿Cómo te llamas?', style: text.headlineMedium),
              const SizedBox(height: Insets.sm),
              Text(
                'El chofer necesita saber por quién preguntar cuando llegue.',
                style: text.bodyLarge?.copyWith(color: BrandColors.grey600),
              ),
              const SizedBox(height: Insets.xxxl),
              const FieldLabel('Nombre completo'),
              const SizedBox(height: Insets.sm),
              TextFormField(
                controller: _name,
                autofocus: true,
                textCapitalization: TextCapitalization.words,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(hintText: 'Ramón Peña'),
                validator: (value) {
                  final trimmed = value?.trim() ?? '';
                  if (trimmed.length < 3) return 'Escribe tu nombre completo.';
                  return null;
                },
              ),
              const SizedBox(height: Insets.xl),
              const FieldLabel('Correo electrónico (opcional)'),
              const SizedBox(height: Insets.sm),
              TextFormField(
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                textInputAction: TextInputAction.done,
                decoration: const InputDecoration(
                  hintText: 'Para recibir tus facturas',
                ),
                validator: (value) {
                  final trimmed = value?.trim() ?? '';
                  if (trimmed.isEmpty) return null;
                  final valid = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$')
                      .hasMatch(trimmed);
                  return valid ? null : 'Ese correo no parece válido.';
                },
              ),
              const SizedBox(height: Insets.xl),
              SwitchListTile.adaptive(
                value: _wantsFiscalReceipt,
                onChanged: (value) => setState(() => _wantsFiscalReceipt = value),
                contentPadding: EdgeInsets.zero,
                title: Text('Necesito factura con RNC', style: text.titleSmall),
                subtitle: Text(
                  'Para deducir el ITBIS. Emitimos comprobante de crédito '
                  'fiscal en vez de consumo.',
                  style: text.bodySmall?.copyWith(color: BrandColors.grey600),
                ),
              ),
              if (_wantsFiscalReceipt) ...[
                const SizedBox(height: Insets.md),
                TextFormField(
                  controller: _rnc,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(hintText: 'RNC de la empresa'),
                  validator: (value) {
                    if (!_wantsFiscalReceipt) return null;
                    final digits = (value ?? '').replaceAll(RegExp(r'\D'), '');
                    // Dominican RNC is 9 digits; a cédula used as RNC is 11.
                    if (digits.length != 9 && digits.length != 11) {
                      return 'El RNC debe tener 9 u 11 dígitos.';
                    }
                    return null;
                  },
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: Insets.lg),
                InlineNotice(message: _error!, tone: NoticeTone.error),
              ],
              const SizedBox(height: Insets.xxl),
              ElevatedButton(
                onPressed: _saving ? null : _save,
                child: _saving
                    ? const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.4,
                          color: BrandColors.white,
                        ),
                      )
                    : const Text('Continuar'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
