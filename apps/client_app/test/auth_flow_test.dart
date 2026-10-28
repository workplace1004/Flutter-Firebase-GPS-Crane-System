import 'package:client_app/app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grua_core/grua_core.dart';
import 'package:grua_testing/grua_testing.dart';
import 'package:intl/date_symbol_data_local.dart';

/// The demo sign-in, with the two things a real phone does that the demo does
/// not: every SMS has its own verification id, and Android may verify the
/// number without sending one.
class _PhoneAuth extends DemoAuthRepository {
  _PhoneAuth(super._backend, {this.instant = false});

  /// Signs in straight away instead of sending a code.
  final bool instant;

  var _sent = 0;

  /// The id the latest SMS carries. Only its code signs in.
  String get latestId => 'vid-$_sent';

  @override
  Future<Result<String>> startPhoneVerification(String e164Phone) async {
    if (instant) {
      await super.confirmSmsCode(verificationId: '', smsCode: '000000');
      return const Result.ok(AuthRepository.phoneSignedIn);
    }
    _sent++;
    return Result.ok(latestId);
  }

  @override
  Future<Result<void>> confirmSmsCode({
    required String verificationId,
    required String smsCode,
  }) async {
    if (verificationId != latestId) {
      return const Result.err(Failure(FailureCode.invalidInput));
    }
    return await super.confirmSmsCode(
      verificationId: verificationId,
      smsCode: smsCode,
    );
  }
}

/// A seeded backend signed in as a number with no account yet: the server
/// has made only the blank `users/` document every new sign-in gets.
DemoBackend _newCustomer() {
  final backend = DemoBackend()..seed();
  return backend
    ..upsertUser(const AppUser(id: 'demo-client-new', phone: '+18095551234'))
    ..currentUserId = 'demo-client-new';
}

Future<void> main() async {
  setUpAll(() => initializeDateFormatting('es_DO'));

  Widget harness(DemoBackend backend, {bool instant = false}) => ProviderScope(
        overrides: [
          appConfigProvider.overrideWithValue(
            const AppConfig(
              flavor: Flavor.dev,
              appKind: AppKind.client,
              firebaseProjectId: 'grua-rd-test',
              googleMapsApiKey: '',
              useEmulators: false,
              emulatorHost: 'localhost',
              functionsRegion: 'us-east1',
            ),
          ),
          ...demoOverrides(
            backend: backend,
            authRepository: _PhoneAuth(backend, instant: instant),
          ),
        ],
        child: const ClientApp(),
      );

  Future<void> sendCode(WidgetTester tester) async {
    await tester.tap(find.text('Entrar con Teléfono'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).first, '8095551234');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Enviar código'));
    await tester.pumpAndSettle(const Duration(seconds: 1));
  }

  testWidgets('the code from a resent SMS signs in', (tester) async {
    await tester.pumpWidget(harness(DemoBackend()..seed()));
    await tester.pumpAndSettle();
    await sendCode(tester);
    expect(find.text('Ingresa el código'), findsOneWidget);

    // Resend unlocks after the cooldown, and the second SMS has its own id.
    await tester.pump(const Duration(seconds: 61));
    await tester.tap(find.text('Reenviar código'));
    await tester.pumpAndSettle(const Duration(seconds: 1));
    expect(find.text('Código reenviado.'), findsOneWidget);

    // The bug: checked against the first id, the new code was always wrong.
    await tester.enterText(find.byType(TextField).first, '222222');
    await tester.pumpAndSettle(const Duration(seconds: 1));
    expect(find.text('PEDIR GRÚA 24/7'), findsOneWidget);
  });

  testWidgets('a number Android verifies on its own skips the code screen',
      (tester) async {
    await tester.pumpWidget(harness(DemoBackend()..seed(), instant: true));
    await tester.pumpAndSettle();
    await sendCode(tester);

    expect(find.text('Ingresa el código'), findsNothing);
    expect(find.text('PEDIR GRÚA 24/7'), findsOneWidget);
  });

  testWidgets('answers from an abandoned registration are not written on a '
      'later sign-in', (tester) async {
    await tester.pumpWidget(harness(_newCustomer()));
    await tester.pumpAndSettle();

    // Starts registering, sends the code, then backs out to the welcome screen.
    await tester.tap(find.text('Registrarme'));
    await tester.pumpAndSettle();
    final fields = find.byType(TextFormField);
    await tester.enterText(fields.at(0), 'Andrés Familia');
    await tester.enterText(fields.at(1), '8095551234');
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Crear cuenta'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Crear cuenta'));
    await tester.pumpAndSettle(const Duration(seconds: 1));
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();

    // A plain sign-in with the phone instead.
    await sendCode(tester);
    await tester.enterText(find.byType(TextField).first, '111111');
    await tester.pumpAndSettle(const Duration(seconds: 1));

    // Still nameless, so asked for one, rather than named after the form.
    expect(find.text('¿Cómo te llamas?'), findsOneWidget);
    expect(find.text('Hola, Andrés'), findsNothing);
  });

  testWidgets('a signed-in customer with no profile yet is asked for a name',
      (tester) async {
    // No `users/` document at all: making it failed, or has not happened yet.
    final backend = DemoBackend()
      ..seed()
      ..currentUserId = 'demo-client-missing';
    await tester.pumpWidget(harness(backend));
    await tester.pumpAndSettle();
    await sendCode(tester);
    await tester.enterText(find.byType(TextField).first, '111111');
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(find.text('¿Cómo te llamas?'), findsOneWidget);
    expect(find.text('PEDIR GRÚA 24/7'), findsNothing);
  });
}
