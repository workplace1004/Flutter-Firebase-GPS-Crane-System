import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:grua_core/grua_core.dart';


class OtpScreen extends ConsumerStatefulWidget {
  const OtpScreen({required this.verificationId, required this.phone, super.key});

  final String verificationId;
  final String phone;

  @override
  ConsumerState<OtpScreen> createState() => _OtpScreenState();
}

class _OtpScreenState extends ConsumerState<OtpScreen> {
  final _controller = TextEditingController();
  final _focus = FocusNode();

  var _verifying = false;
  String? _error;

  /// The id the code is checked against. Every SMS comes with its own, so a
  /// resend replaces it: checking the new code against the first id is always
  /// "código incorrecto".
  late String _verificationId = widget.verificationId;

  /// Resend is locked for a minute. Without it, a user tapping "reenviar"
  /// impatiently burns SMS credit and hits the provider's rate limit, which
  /// then blocks the legitimate retry.
  static const _resendCooldown = Duration(seconds: 60);
  Timer? _timer;
  var _secondsLeft = 60;

  @override
  void initState() {
    super.initState();
    _startCooldown();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _startCooldown() {
    _timer?.cancel();
    setState(() => _secondsLeft = _resendCooldown.inSeconds);
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return timer.cancel();
      setState(() => _secondsLeft--);
      if (_secondsLeft <= 0) timer.cancel();
    });
  }

  Future<void> _verify(String code) async {
    if (_verifying) return;
    setState(() {
      _verifying = true;
      _error = null;
    });

    final result = await ref.read(authRepositoryProvider).confirmSmsCode(
          verificationId: _verificationId,
          smsCode: code,
        );
    if (!mounted) return;

    // Signed in: the router leaves this screen (home, or the profile step for
    // a new account), and the app root writes any registration answers.
    if (result case Err(:final failure)) {
      setState(() {
        _verifying = false;
        _error = failure.userMessage;
        _controller.clear();
        _focus.requestFocus();
      });
    }
  }

  Future<void> _resend() async {
    if (_secondsLeft > 0) return;
    final result =
        await ref.read(authRepositoryProvider).startPhoneVerification(widget.phone);
    if (!mounted) return;

    switch (result) {
      // Android verified the number on its own; the router takes it from here.
      case Ok(value: AuthRepository.phoneSignedIn):
        return;
      case Ok(value: final verificationId):
        _verificationId = verificationId;
        _controller.clear();
        _startCooldown();
        setState(() => _error = null);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Código reenviado.')),
        );
      case Err(:final failure):
        setState(() => _error = failure.userMessage);
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final pretty = widget.phone.length == 12
        ? '${widget.phone.substring(2, 5)}-'
            '${widget.phone.substring(5, 8)}-${widget.phone.substring(8)}'
        : widget.phone;

    return Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: () => context.pop()),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(
            horizontal: Insets.gutter,
            vertical: Insets.xl,
          ),
          children: [
            const Center(child: GruaLogo(size: 180)),
            const SizedBox(height: Insets.xl),
            Text('Ingresa el código', style: text.headlineMedium),
            const SizedBox(height: Insets.sm),
            Text.rich(
              TextSpan(
                style: text.bodyLarge?.copyWith(color: BrandColors.grey600),
                children: [
                  const TextSpan(text: 'Enviamos un código de 6 dígitos al '),
                  TextSpan(
                    text: pretty,
                    style: text.bodyLarge?.copyWith(
                      color: BrandColors.ink,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const TextSpan(text: '.'),
                ],
              ),
            ),
            const SizedBox(height: Insets.xxxl),
            _CodeField(
              controller: _controller,
              focusNode: _focus,
              enabled: !_verifying,
              hasError: _error != null,
              onCompleted: _verify,
              onChanged: (_) {
                if (_error != null) setState(() => _error = null);
              },
            ),
            if (_error != null) ...[
              const SizedBox(height: Insets.xl),
              InlineNotice(message: _error!, tone: NoticeTone.error),
            ],
            const SizedBox(height: Insets.xxl),
            if (_verifying)
              const BrandLoader(message: 'Verificando…')
            else
              Center(
                child: TextButton(
                  onPressed: _secondsLeft > 0 ? null : _resend,
                  child: Text(
                    _secondsLeft > 0
                        ? 'Reenviar código en $_secondsLeft s'
                        : 'Reenviar código',
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Six boxes over one hidden field. A single field keeps paste, autofill and
/// SMS auto-retrieval working, which per-digit fields all break.
class _CodeField extends StatelessWidget {
  const _CodeField({
    required this.controller,
    required this.focusNode,
    required this.enabled,
    required this.hasError,
    required this.onCompleted,
    required this.onChanged,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool enabled;
  final bool hasError;
  final ValueChanged<String> onCompleted;
  final ValueChanged<String> onChanged;

  static const _length = 6;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        ValueListenableBuilder<TextEditingValue>(
          valueListenable: controller,
          builder: (context, value, _) {
            final digits = value.text;
            return Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                for (var i = 0; i < _length; i++)
                  _Box(
                    digit: i < digits.length ? digits[i] : '',
                    active: enabled && i == digits.length,
                    hasError: hasError,
                  ),
              ],
            );
          },
        ),
        Positioned.fill(
          child: Opacity(
            opacity: 0,
            child: TextField(
              controller: controller,
              focusNode: focusNode,
              enabled: enabled,
              autofocus: true,
              keyboardType: TextInputType.number,
              autofillHints: const [AutofillHints.oneTimeCode],
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(_length),
              ],
              onChanged: (value) {
                onChanged(value);
                if (value.length == _length) onCompleted(value);
              },
            ),
          ),
        ),
      ],
    );
  }
}

class _Box extends StatelessWidget {
  const _Box({required this.digit, required this.active, required this.hasError});

  final String digit;
  final bool active;
  final bool hasError;

  @override
  Widget build(BuildContext context) {
    final borderColor = hasError
        ? BrandColors.danger
        : active
            ? BrandColors.red
            : BrandColors.grey200;

    return AnimatedContainer(
      duration: Motion.fast,
      width: 48,
      height: 60,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: BrandColors.white,
        borderRadius: Corners.brMd,
        border: Border.all(color: borderColor, width: active ? 1.8 : 1.2),
      ),
      child: Text(
        digit,
        style: Theme.of(context).textTheme.headlineSmall,
      ),
    );
  }
}
