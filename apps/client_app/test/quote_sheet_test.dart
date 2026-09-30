import 'package:client_app/features/request/quote_sheet.dart';
import 'package:client_app/features/request/request_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grua_core/grua_core.dart';
import 'package:grua_testing/grua_testing.dart';

/// What the customer reads before confirming.
void main() {
  const config = PricingConfig();

  QuoteResult priced(VehicleType type, double km) => QuoteResult(
        quote: Pricing.quoteFor(
          config: config,
          vehicleType: type,
          distance: TripDistance.city(km, includedKm: config.includedKm),
          // Midday in Santo Domingo: no night surcharge.
          at: DateTime.utc(2026, 6, 15, 16),
          chargeItbis: false,
        ),
        route: const ServiceRoute(distanceMeters: 8000, durationSeconds: 900),
        expiresAt: DateTime.now().toUtc().add(const Duration(minutes: 10)),
        signature: 'test-signature',
        truckType: ServiceVehicle(type: type).inferredTruckType,
      );

  Future<void> pumpSheet(WidgetTester tester, QuoteResult quote) async {
    tester.view
      ..devicePixelRatio = 1
      ..physicalSize = const Size(430, 1400);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...demoOverrides(),
          requestControllerProvider.overrideWith(
            () => _Priced(RequestDraft(quote: quote)),
          ),
        ],
        child: const MaterialApp(home: Scaffold(body: QuoteSheet())),
      ),
    );
    await tester.pump();
  }

  testWidgets('says the distance and the estimated total in one line', (tester) async {
    await pumpSheet(tester, priced(VehicleType.sedan, 8));

    expect(find.text(r'Distancia: 8km | Total estimado: RD$1,710'), findsOneWidget);
    expect(find.text('CONFIRMAR Y PEDIR GRÚA'), findsOneWidget);
    expect(find.byKey(const Key('quote-heavy-notice')), findsNothing);
  });

  testWidgets('a heavy vehicle is told the operator confirms first', (tester) async {
    await pumpSheet(tester, priced(VehicleType.camion, 12));

    expect(
      find.text(r'Distancia: 12km | Total estimado: RD$6,750'),
      findsOneWidget,
    );
    expect(find.text(heavyServiceNotice), findsOneWidget);
    expect(find.text('ENVIAR SOLICITUD'), findsOneWidget);
  });
}

class _Priced extends RequestController {
  _Priced(this.draft);

  final RequestDraft draft;

  @override
  RequestDraft build() => draft;
}
