import 'dart:async';
import 'dart:typed_data';

import 'package:admin_web/app.dart';
import 'package:admin_web/features/drivers/create_driver_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:grua_core/grua_core.dart';
import 'package:grua_testing/grua_testing.dart';
import 'package:intl/date_symbol_data_local.dart';

/// Panel tests.
///
/// The panel is a desktop tool, so these run at a desktop size; the
/// too-small-screen path gets its own test rather than being an accident of the
/// default 800x600 test window.
Future<void> main() async {
  setUpAll(() => initializeDateFormatting('es_DO'));

  const config = AppConfig(
    flavor: Flavor.dev,
    appKind: AppKind.admin,
    firebaseProjectId: 'grua-rd-test',
    googleMapsApiKey: '',
    useEmulators: false,
    emulatorHost: 'localhost',
    functionsRegion: 'us-east1',
  );

  /// Stands in for the native file dialog, which a widget test cannot drive.
  DocumentPicker pickerReturning(String name) => () async => PickedDocument(
        name: name,
        bytes: Uint8List.fromList(List.filled(64, 7)),
        extension: name.split('.').last,
      );

  Widget harness(
    DemoBackend backend, {
    DocumentPicker? picker,
    List<Override> overrides = const [],
  }) =>
      ProviderScope(
        overrides: [
          appConfigProvider.overrideWithValue(config),
          ...demoOverrides(
            backend: backend,
            role: UserRole.admin,
            actingAs: 'admin-1',
          ),
          if (picker != null) ...[
            documentPickerProvider.overrideWithValue(picker),
            avatarPickerProvider.overrideWithValue(pickerReturning('chofer.jpg')),
          ],
          ...overrides,
        ],
        child: const AdminApp(),
      );

  /// Sets a logical window size.
  ///
  /// `physicalSize` is in device pixels and the test view defaults to a device
  /// pixel ratio of 3, so setting 1440 there actually yields a 480-px logical
  /// window — which silently put every test on the too-small-screen path.
  void setWindow(WidgetTester tester, Size logical) {
    tester.view
      ..devicePixelRatio = 1.0
      ..physicalSize = logical;
    addTearDown(tester.view.reset);
  }

  void setDesktopSize(WidgetTester tester) =>
      setWindow(tester, const Size(1440, 900));

  Future<void> signIn(WidgetTester tester) async {
    await tester.enterText(find.byType(TextFormField).first, 'ops@gruasrd.do');
    await tester.enterText(find.byType(TextFormField).last, 'secret123');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Entrar'));
    await tester.pumpAndSettle(const Duration(seconds: 1));
  }

  testWidgets('a signed-out visitor gets the login card', (tester) async {
    setDesktopSize(tester);
    await tester.pumpWidget(harness(DemoBackend()..seed()));
    await tester.pumpAndSettle();

    expect(find.text('Panel de operaciones y aseguradoras'), findsOneWidget);
  });

  testWidgets('signing in lands on operations with the sidebar',
      (tester) async {
    setDesktopSize(tester);
    await tester.pumpWidget(harness(DemoBackend()..seed()));
    await tester.pumpAndSettle();

    await signIn(tester);

    expect(find.text('Operaciones'), findsOneWidget);
    expect(find.text('Choferes'), findsWidgets);
    expect(find.text('Solicitudes'), findsOneWidget);
    expect(find.text('Activos'), findsOneWidget);
    // FieldLabel uppercases, so the legend renders as 'FLOTA EN LÍNEA'.
    expect(find.text('FLOTA EN LÍNEA'), findsOneWidget);
  });

  testWidgets('the flota tab lists every chofer, working or not',
      (tester) async {
    setDesktopSize(tester);
    await tester.pumpWidget(harness(DemoBackend()..seed()));
    await tester.pumpAndSettle();
    await signIn(tester);

    await tester.tap(find.text('Flota'));
    await tester.pumpAndSettle();

    // The jobs list gave way to the roster, and the whole roster is there:
    // an account that cannot work is labelled, not hidden, because the
    // dispatcher still needs to know the truck exists.
    expect(find.text('Todo tranquilo'), findsNothing);
    expect(find.text('Luis Fernández'), findsOneWidget);
    expect(find.text('Pedro Aybar'), findsOneWidget);
    expect(find.text('Inactivo'), findsWidgets);
  });

  testWidgets('a request a customer just sent shows up with both its ends',
      (tester) async {
    setDesktopSize(tester);
    final backend = DemoBackend()..seed();
    await tester.pumpWidget(harness(backend));
    await tester.pumpAndSettle();
    await signIn(tester);

    // Nothing in flight: the queue says so, rather than saying nothing.
    expect(find.text('Sin solicitudes'), findsOneWidget);

    // A customer asks for a grúa. Nobody tells the panel — it is watching the
    // same services stream the customer's own screen is.
    backend.createService(
      clientId: 'demo-client-1',
      pickup: const ServiceLocation(
        geo: LatLng(19.1221, -70.6367),
        address: 'Maria Auxiliadora, Jarabacoa',
        reference: 'Frente a la Farmacia San Miguel',
      ),
      dropoff: const ServiceLocation(
        geo: LatLng(19.1300, -70.6400),
        address: 'Carr. Palo Blanco, Jarabacoa',
      ),
      vehicle: const ServiceVehicle(make: 'Toyota', model: 'Corolla'),
      truckType: TruckType.gancho,
      quote: const Quote(totalCents: 250000),
      route: const ServiceRoute(distanceMeters: 4200),
    );
    await tester.pump(const Duration(milliseconds: 100));

    // It is on the dispatcher's screen, and the row carries the whole job:
    // who, what, from where, to where.
    expect(find.text('Sin solicitudes'), findsNothing);
    expect(find.textContaining('Ramón Peña'), findsWidgets);
    expect(find.text('Maria Auxiliadora, Jarabacoa'), findsOneWidget);
    expect(find.text('Carr. Palo Blanco, Jarabacoa'), findsOneWidget);
    expect(find.text('Frente a la Farmacia San Miguel'), findsOneWidget);

    // And the map draws the trip, not just the pin it starts from.
    final map = tester.widget<GruaMap>(find.byType(GruaMap));
    expect(
      map.markers.where((m) => m.kind == MapMarkerKind.dropoff),
      isNotEmpty,
    );
    expect(map.routes, isNotEmpty);

    backend.dispose();
    await tester.pump();
  });

  testWidgets('opening a request shows the customer and the trip in the drawer',
      (tester) async {
    setDesktopSize(tester);
    final backend = DemoBackend()..seed();
    await tester.pumpWidget(harness(backend));
    await tester.pumpAndSettle();
    await signIn(tester);

    backend.createService(
      clientId: 'demo-client-1',
      pickup: const ServiceLocation(
        geo: LatLng(19.1221, -70.6367),
        address: 'Maria Auxiliadora, Jarabacoa',
        reference: 'Frente a la Farmacia San Miguel',
      ),
      dropoff: const ServiceLocation(
        geo: LatLng(19.1300, -70.6400),
        address: 'Carr. Palo Blanco, Jarabacoa',
      ),
      vehicle: const ServiceVehicle(make: 'Toyota', model: 'Corolla'),
      truckType: TruckType.gancho,
      quote: const Quote(totalCents: 250000),
      route: const ServiceRoute(distanceMeters: 4200),
    );
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.text('Maria Auxiliadora, Jarabacoa'));
    await tester.pump(const Duration(milliseconds: 100));

    // The drawer: the customer's phone to call them back, and the vehicle the
    // chofer is being sent to.
    expect(find.text('+18095551234'), findsOneWidget);
    expect(find.text('Toyota Corolla'), findsWidgets);
    // Nobody has taken it, so the dispatcher gets the manual assignment panel.
    expect(find.text('Asignar manualmente'), findsOneWidget);

    backend.dispose();
    await tester.pump();
  });

  testWidgets('the map says when the tow is a straight line, not the road',
      (tester) async {
    // The bug: with no stored route and no answer from the browser, the panel
    // drew the straight-line fallback as a solid line like any other route.
    // A dispatcher read it as a road through the middle of the Ensanche.
    setDesktopSize(tester);
    final backend = DemoBackend()..seed();
    await tester.pumpWidget(harness(backend));
    await tester.pumpAndSettle();
    await signIn(tester);

    const pickup = ServiceLocation(
      geo: LatLng(18.4795, -69.9420),
      address: 'Gazcue, Santo Domingo',
    );
    const dropoff = ServiceLocation(
      geo: LatLng(18.5001, -69.8800),
      address: 'Villa Consuelo, Santo Domingo',
    );

    // Quoted before anything routed it: no polyline on the service.
    final straight = backend.createService(
      clientId: 'demo-client-1',
      pickup: pickup,
      dropoff: dropoff,
      vehicle: const ServiceVehicle(make: 'Toyota', model: 'Corolla'),
      truckType: TruckType.gancho,
      quote: const Quote(totalCents: 250000),
      route: const ServiceRoute(distanceMeters: 8000),
    );
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.text(straight.code));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Ruta aproximada, no por calles'), findsOneWidget);
    expect(
      tester
          .widgetList<SchematicMap>(find.byType(SchematicMap))
          .expand((map) => map.routes)
          .any((route) => route.dashed && route.points.length == 2),
      isTrue,
    );

    // The same trip with the road the server stored: drawn as the road, and
    // the warning goes away.
    final routed = backend.createService(
      clientId: 'demo-client-1',
      pickup: pickup,
      dropoff: dropoff,
      vehicle: const ServiceVehicle(make: 'Honda', model: 'Civic'),
      truckType: TruckType.gancho,
      quote: const Quote(totalCents: 250000),
      route: const ServiceRoute(
        distanceMeters: 8000,
        polyline: '{gxoBnp{iL{T_jAwj@_|Bod@w|AsXw|A',
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.text(routed.code));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Ruta aproximada, no por calles'), findsNothing);
    expect(
      tester
          .widgetList<SchematicMap>(find.byType(SchematicMap))
          .expand((map) => map.routes)
          .any((route) => !route.dashed && route.points.length == 5),
      isTrue,
    );

    // And with nothing open, the queue draws each job on its roads too. This
    // is the state the dispatcher watches all night: it used to draw every
    // queued tow as a line straight across the city.
    await tester.tap(find.byIcon(Icons.close).first);
    await tester.pump(const Duration(milliseconds: 100));

    final queued = tester
        .widgetList<SchematicMap>(find.byType(SchematicMap))
        .expand((map) => map.routes)
        .toList();
    expect(queued.any((route) => route.points.length == 5), isTrue);

    backend.dispose();
    await tester.pump();
  });

  testWidgets('a heavy request waits for the operator to confirm the price',
      (tester) async {
    setDesktopSize(tester);
    final backend = DemoBackend(dispatchDelay: const Duration(minutes: 5))
      ..seed();
    await tester.pumpWidget(harness(backend));
    await tester.pumpAndSettle();
    await signIn(tester);

    final service = backend.createService(
      clientId: 'demo-client-1',
      pickup: const ServiceLocation(
        geo: LatLng(18.4795, -69.9420),
        address: 'Zona industrial de Haina',
      ),
      dropoff: const ServiceLocation(geo: LatLng(18.5001, -69.8800)),
      vehicle: const ServiceVehicle(make: 'Mack', type: VehicleType.patana),
      truckType: TruckType.pesada,
      quote: const Quote(totalCents: 1000000, subtotalCents: 1000000),
      route: const ServiceRoute(distanceMeters: 10000),
    );
    await tester.pump(const Duration(milliseconds: 100));

    // In the queue as something to confirm, naming what kind of vehicle.
    expect(find.text('Por confirmar'), findsWidgets);
    expect(find.textContaining('Patana / Tráiler'), findsWidgets);

    await tester.tap(find.text('Zona industrial de Haina'));
    await tester.pump(const Duration(milliseconds: 100));

    // No chofer list: nobody goes before the price is agreed.
    expect(find.byKey(const Key('heavy-review-notice')), findsOneWidget);
    expect(find.text('Asignar manualmente'), findsNothing);
    expect(find.text('Confirmar precio final'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('heavy-price')), '12,500');
    await tester.ensureVisible(find.byKey(const Key('heavy-confirm')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('heavy-confirm')));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();

    final confirmed = backend.service(service.id)!;
    expect(confirmed.status, ServiceStatus.pendingDispatch);
    expect(confirmed.totalCents, 1250000);
    expect(confirmed.operatorReview!.isConfirmed, isTrue);
    expect(find.textContaining('Precio confirmado'), findsOneWidget);
    // Confirmed, it is an ordinary request: the office can assign by hand.
    expect(find.text('Confirmar precio final'), findsNothing);

    backend.dispose();
    await tester.pump();
  });

  testWidgets('Asignar actually sends the chofer, and says so', (tester) async {
    // The bug: this button showed "Asignando a …" and called nothing at all.
    // No `assignServiceManually` existed in the app, so the chofer it named
    // was never told and the request sat exactly where it was.
    setDesktopSize(tester);
    final backend = DemoBackend(dispatchDelay: const Duration(minutes: 5))
      ..seed();
    await tester.pumpWidget(harness(backend));
    await tester.pumpAndSettle();
    await signIn(tester);

    final service = backend.createService(
      clientId: 'demo-client-1',
      pickup: const ServiceLocation(
        geo: LatLng(18.4795, -69.9420),
        address: 'Gazcue',
      ),
      dropoff: const ServiceLocation(geo: LatLng(18.5001, -69.8800)),
      vehicle: const ServiceVehicle(condition: VehicleCondition.noArranca),
      truckType: TruckType.gancho,
      quote: const Quote(totalCents: 250000),
      route: const ServiceRoute(distanceMeters: 8000),
    );
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.text('Gazcue'));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Asignar manualmente'), findsOneWidget);
    // The drawer is a long list; the panel sits well below the fold.
    await tester.ensureVisible(find.text('Asignar').first);
    await tester.pump();
    await tester.tap(find.text('Asignar').first);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();

    // The job now belongs to somebody, and the panel says who.
    final assigned = backend.service(service.id)!;
    expect(assigned.hasDriver, isTrue);
    expect(assigned.status, ServiceStatus.accepted);
    expect(assigned.assignmentMode, AssignmentMode.manual);
    expect(find.textContaining('va en camino'), findsOneWidget);

    // The panel is gone with the job it was for, and the drawer offers the
    // chofer instead of a list of candidates.
    expect(find.text('Asignar manualmente'), findsNothing);
    expect(find.text('Contactar chofer'), findsOneWidget);

    backend.dispose();
    await tester.pump();
  });

  testWidgets('the queue says whether a chofer has been asked yet',
      (tester) async {
    // A customer sees "Buscando grúa" for both `pending_dispatch` and
    // `offered`. A dispatcher must not: "nobody has been asked" and "a chofer
    // is deciding right now" are different problems, and the panel showed the
    // customer's word for both.
    setDesktopSize(tester);
    final backend = DemoBackend()..seed();
    await tester.pumpWidget(harness(backend));
    await tester.pumpAndSettle();
    await signIn(tester);

    backend.createService(
      clientId: 'demo-client-1',
      pickup: const ServiceLocation(
        geo: LatLng(18.4795, -69.9420),
        address: 'Gazcue',
      ),
      dropoff: const ServiceLocation(geo: LatLng(18.5001, -69.8800)),
      vehicle: const ServiceVehicle(condition: VehicleCondition.noArranca),
      truckType: TruckType.gancho,
      quote: const Quote(totalCents: 250000),
      route: const ServiceRoute(distanceMeters: 8000),
    );
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Buscando chofer'), findsOneWidget);
    expect(find.text('Buscando grúa'), findsNothing);

    backend.dispose();
    await tester.pump();
  });

  testWidgets('opening a request leaves only the trucks that could take it',
      (tester) async {
    setDesktopSize(tester);
    final backend = DemoBackend()..seed();
    await tester.pumpWidget(harness(backend));
    await tester.pumpAndSettle();
    await signIn(tester);

    // Every truck on the road is on the map while nothing is selected.
    final wholeFleet = tester
        .widget<GruaMap>(find.byType(GruaMap))
        .markers
        .where((m) => m.id?.startsWith('driver:') ?? false)
        .length;
    expect(wholeFleet, greaterThan(1));

    backend.createService(
      clientId: 'demo-client-1',
      pickup: const ServiceLocation(
        geo: LatLng(18.4795, -69.9420),
        address: 'Gazcue',
      ),
      dropoff: const ServiceLocation(geo: LatLng(18.5001, -69.8800)),
      // A car that will not start: a gancho job, which a plataforma can also
      // take and a grúa pesada cannot.
      vehicle: const ServiceVehicle(condition: VehicleCondition.noArranca),
      truckType: TruckType.gancho,
      quote: const Quote(totalCents: 250000),
      route: const ServiceRoute(distanceMeters: 8000),
    );
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.text('Gazcue'));
    await tester.pump(const Duration(milliseconds: 100));

    final shown = tester
        .widget<GruaMap>(find.byType(GruaMap))
        .markers
        .where((m) => m.id?.startsWith('driver:') ?? false)
        .map((m) => m.id!.substring('driver:'.length))
        .toSet();

    // Only trucks that could actually do this job, and fewer than the fleet.
    expect(shown, isNotEmpty);
    expect(shown.length, lessThan(wholeFleet));
    for (final id in shown) {
      final driver = backend.driver(id)!;
      expect(
        driver.truckType.canServe(TruckType.gancho),
        isTrue,
        reason: '${driver.shortName} drives a ${driver.truckType.label}',
      );
      expect(driver.isBusy, isFalse);
    }

    // And the map says what it has been narrowed to, so the fleet does not
    // look like it vanished.
    expect(find.textContaining('para Gancho'), findsOneWidget);

    // One job at a time: only this request's two ends are drawn, and the
    // camera frames the job together with the trucks that could take it.
    final map = tester.widget<GruaMap>(find.byType(GruaMap));
    expect(
      map.markers.where((m) => m.kind == MapMarkerKind.pickup),
      hasLength(1),
    );
    expect(map.fitTo, contains(const LatLng(18.4795, -69.9420)));
    expect(map.fitTo, contains(const LatLng(18.5001, -69.8800)));
    expect(map.fitTo.length, greaterThanOrEqualTo(2 + shown.length));

    backend.dispose();
    await tester.pump();
  });

  testWidgets('picking a chofer from the flota opens their card',
      (tester) async {
    setDesktopSize(tester);
    await tester.pumpWidget(harness(DemoBackend()..seed()));
    await tester.pumpAndSettle();
    await signIn(tester);

    await tester.tap(find.text('Flota'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Luis Fernández'));
    await tester.pumpAndSettle();

    // The drawer, beside the row that is still in the list.
    expect(find.text('Luis Fernández'), findsNWidgets(2));
    expect(find.text('001-1234567-8'), findsOneWidget);
    expect(find.text('Ver ficha completa'), findsOneWidget);
  });

  testWidgets('the flota search narrows the roster', (tester) async {
    setDesktopSize(tester);
    await tester.pumpWidget(harness(DemoBackend()..seed()));
    await tester.pumpAndSettle();
    await signIn(tester);

    await tester.tap(find.text('Flota'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Nombre, cédula o placa'),
      'Pedro',
    );
    await tester.pumpAndSettle();

    expect(find.text('Pedro Aybar'), findsOneWidget);
    expect(find.text('Luis Fernández'), findsNothing);
  });

  testWidgets('the drivers screen lists the seeded fleet', (tester) async {
    setDesktopSize(tester);
    await tester.pumpWidget(harness(DemoBackend()..seed()));
    await tester.pumpAndSettle();
    await signIn(tester);

    await tester.tap(find.text('Choferes').last);
    await tester.pumpAndSettle();

    expect(find.text('Luis Fernández'), findsOneWidget);
    expect(find.text('Pedro Aybar'), findsOneWidget);
    // Cédulas render in the form printed on the card.
    expect(find.text('001-1234567-8'), findsOneWidget);
  });

  testWidgets('the drivers screen shows a spinner until the roster arrives',
      (tester) async {
    setDesktopSize(tester);
    final backend = DemoBackend()..seed();
    // A roster query that has not answered yet, as on a slow connection.
    final pending = StreamController<List<Driver>>();
    addTearDown(pending.close);
    await tester.pumpWidget(
      harness(
        backend,
        overrides: [allDriversProvider.overrideWith((ref) => pending.stream)],
      ),
    );
    await tester.pumpAndSettle();
    await signIn(tester);

    await tester.tap(find.text('Choferes').last);
    // Not pumpAndSettle: the spinner animates for as long as it is shown.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Cargando choferes…'), findsOneWidget);
    // "No results" while nothing has loaded yet would be a lie.
    expect(find.text('Sin resultados'), findsNothing);

    pending.add(backend.allDrivers);
    await tester.pumpAndSettle();

    expect(find.text('Cargando choferes…'), findsNothing);
    expect(find.text('Luis Fernández'), findsOneWidget);
  });

  testWidgets('the clients screen lists registered customers', (tester) async {
    setDesktopSize(tester);
    await tester.pumpWidget(harness(DemoBackend()..seed()));
    await tester.pumpAndSettle();
    await signIn(tester);

    await tester.tap(find.text('Clientes').last);
    await tester.pumpAndSettle();

    expect(find.text('Ramón Peña'), findsOneWidget);
    expect(find.text('809-555-1234'), findsOneWidget);
    // Choferes share the users collection in Firestore but not this roster.
    expect(find.text('Luis Fernández'), findsNothing);
    // The seeded blocked account proves the state renders, not just the name.
    expect(find.text('Bloqueado'), findsOneWidget);
  });

  testWidgets('the client search narrows the roster', (tester) async {
    setDesktopSize(tester);
    await tester.pumpWidget(harness(DemoBackend()..seed()));
    await tester.pumpAndSettle();
    await signIn(tester);

    await tester.tap(find.text('Clientes').last);
    await tester.pumpAndSettle();

    // Typed the way a dispatcher reads it off a screen, with dashes.
    await tester.enterText(find.byType(TextField).last, '809-555-2345');
    await tester.pumpAndSettle();

    expect(find.text('Yokasta Almonte'), findsOneWidget);
    expect(find.text('Ramón Peña'), findsNothing);
  });

  /// Opens the roster and the "Nuevo chofer" form.
  Future<void> openCreateForm(WidgetTester tester) async {
    await signIn(tester);
    await tester.tap(find.text('Choferes').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Nuevo chofer'));
    await tester.pumpAndSettle();
  }

  /// Fills every field the form insists on. [cedula] varies per test.
  Future<void> fillRequiredFields(
    WidgetTester tester, {
    required String cedula,
  }) async {
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Juan Alberto Pérez Núñez'),
      'Wilfredo Antonio Reyes',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, '001-1234567-8'),
      cedula,
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, '(809) 555-1234'),
      '8295557788',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'chofer@gruasrd.do'),
      'wilfredo@gruasrd.do',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Número de licencia'),
      'L-884213',
    );
    await tester.pumpAndSettle();

    // The expiry is a date picker, not a text field: open it and take the
    // default it lands on, a year out.
    // The form scrolls, so each picker is brought into view before the tap.
    await tester.ensureVisible(find.text('dd/mm/aaaa'));
    await tester.tap(find.text('dd/mm/aaaa'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('ACEPTAR'));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Subir foto'));
    await tester.tap(find.text('Subir foto'));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Agregar foto'));
    await tester.tap(find.text('Agregar foto'));
    await tester.pumpAndSettle();
  }

  testWidgets('the new-chofer button opens a form, not a notice',
      (tester) async {
    setDesktopSize(tester);
    await tester.pumpWidget(harness(DemoBackend()..seed()));
    await tester.pumpAndSettle();
    await openCreateForm(tester);

    for (final label in const [
      'Nombre completo',
      'Cédula',
      'Teléfono',
      'Licencia de conducir',
      'Vencimiento licencia',
      'Grúa asignada',
      'Zona de cobertura',
      'Nombre de la empresa',
      'RNC',
    ]) {
      expect(
        find.textContaining(label, findRichText: true),
        findsOneWidget,
        reason: 'missing field: $label',
      );
    }
  });

  testWidgets('a cédula that fails the check digit is refused', (tester) async {
    setDesktopSize(tester);
    await tester.pumpWidget(
      harness(DemoBackend()..seed(), picker: pickerReturning('licencia.jpg')),
    );
    await tester.pumpAndSettle();
    await openCreateForm(tester);

    // Right length, wrong check digit — the typo the server also refuses.
    await fillRequiredFields(tester, cedula: '00112345670');
    await tester.tap(find.text('Crear chofer').last);
    await tester.pumpAndSettle();

    expect(find.text('Esa cédula no es válida.'), findsOneWidget);
  });

  testWidgets('a completed form creates an inactive chofer', (tester) async {
    setDesktopSize(tester);
    final backend = DemoBackend()..seed();
    await tester.pumpWidget(
      harness(backend, picker: pickerReturning('licencia.jpg')),
    );
    await tester.pumpAndSettle();
    await openCreateForm(tester);

    await fillRequiredFields(tester, cedula: '40212345678');
    expect(find.text('licencia.jpg'), findsOneWidget);

    await tester.tap(find.text('Crear chofer').last);
    await tester.pumpAndSettle(const Duration(seconds: 2));

    // The password is readable once, here, and never again.
    expect(find.text('Chofer creado'), findsOneWidget);
    expect(find.text('GruaDemo2026!'), findsOneWidget);

    await tester.tap(find.text('Listo'));
    await tester.pumpAndSettle();

    final created =
        backend.allDrivers.firstWhere((d) => d.cedula == '40212345678');
    expect(created.name, 'Wilfredo Antonio Reyes');
    expect(created.phone, '+18295557788');
    expect(created.status, DriverStatus.inactive);
    expect(created.mustChangePassword, isTrue);
    // The photo went up and landed on the record the roster draws from.
    expect(created.photoUrl, startsWith('data:image/jpeg'));

    // And the roster shows them, with the filters cleared so an inactive
    // account is not hidden behind the one that was set.
    expect(find.text('Wilfredo Antonio Reyes'), findsOneWidget);
  });

  testWidgets('a duplicate cédula is refused rather than creating a second '
      'account', (tester) async {
    setDesktopSize(tester);
    final backend = DemoBackend()..seed();
    await tester.pumpWidget(
      harness(backend, picker: pickerReturning('licencia.jpg')),
    );
    await tester.pumpAndSettle();
    await openCreateForm(tester);

    // Somebody the office already has on file. Seeded through the backend so
    // the test does not depend on a fixture cédula passing the check digit.
    backend.createDriver(
      name: 'Wilfredo Antonio Reyes',
      cedula: '40212345678',
      phone: '+18295557788',
      email: 'wilfredo@gruasrd.do',
      licenseNumber: 'L-884213',
      licenseExpiry: DateTime.now().add(const Duration(days: 300)),
    );

    await fillRequiredFields(tester, cedula: '40212345678');
    await tester.tap(find.text('Crear chofer').last);
    await tester.pumpAndSettle(const Duration(seconds: 2));

    expect(find.text('Ya existe un chofer con esa cédula.'), findsOneWidget);
    expect(
      backend.allDrivers.where((d) => d.cedula == '40212345678').length,
      1,
    );
  });

  /// A chofer with no job and no grúa, so nothing refuses an edit or a delete.
  Driver seedWilfredo(DemoBackend backend) => backend.createDriver(
        name: 'Wilfredo Antonio Reyes',
        cedula: '40212345678',
        phone: '+18295557788',
        email: 'wilfredo@gruasrd.do',
        licenseNumber: 'L-884213',
        licenseExpiry: DateTime.now().add(const Duration(days: 300)),
      )!;

  /// Opens the roster narrowed to one chofer, so that row's buttons are the
  /// only ones on screen.
  Future<void> openRosterFor(WidgetTester tester, String query) async {
    await signIn(tester);
    await tester.tap(find.text('Choferes').last);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Nombre, cédula o placa'),
      query,
    );
    await tester.pumpAndSettle();
    // The actions are the table's last column; on a narrower window they sit
    // past a sideways scroll.
    await tester.ensureVisible(find.byTooltip('Eliminar'));
    await tester.pumpAndSettle();
  }

  testWidgets('each row shows the email and view, edit and delete buttons',
      (tester) async {
    setDesktopSize(tester);
    final backend = DemoBackend()..seed();
    seedWilfredo(backend);
    await tester.pumpWidget(harness(backend));
    await tester.pumpAndSettle();
    await openRosterFor(tester, 'Wilfredo');

    expect(find.text('wilfredo@gruasrd.do'), findsOneWidget);
    expect(find.byTooltip('Ver'), findsOneWidget);
    expect(find.byTooltip('Editar'), findsOneWidget);
    expect(find.byTooltip('Eliminar'), findsOneWidget);

    // "Ver" opens the full record, including what the table has no room for.
    await tester.tap(find.byTooltip('Ver'));
    await tester.pumpAndSettle();
    expect(find.text('L-884213'), findsOneWidget);
    expect(find.text('Toda la cobertura'), findsOneWidget);
  });

  testWidgets('editing a chofer saves the changes but not the cédula',
      (tester) async {
    setDesktopSize(tester);
    final backend = DemoBackend()..seed();
    final wilfredo = seedWilfredo(backend);
    await tester.pumpWidget(harness(backend));
    await tester.pumpAndSettle();
    await openRosterFor(tester, 'Wilfredo');
    await tester.tap(find.byTooltip('Editar'));
    await tester.pumpAndSettle();
    expect(find.text('Editar chofer'), findsOneWidget);
    // Pre-filled the way it was typed, not the way it is stored.
    expect(find.text('(829) 555-7788'), findsOneWidget);
    // The cédula is on file and stays there; the form says as much.
    expect(find.text('Identifica al chofer: no se cambia.'), findsOneWidget);

    // The form has to hold together on the narrowest window the panel allows.
    tester.view.physicalSize = const Size(1024, 768);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    setDesktopSize(tester);
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(TextFormField, 'wilfredo@gruasrd.do'),
      'wreyes@gruasrd.do',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Guardar cambios'));
    await tester.pumpAndSettle(const Duration(seconds: 2));

    final saved = backend.driver(wilfredo.id)!;
    expect(saved.email, 'wreyes@gruasrd.do');
    expect(saved.cedula, '40212345678');
    expect(find.text('Cambios guardados.'), findsOneWidget);
    expect(find.text('wreyes@gruasrd.do'), findsOneWidget);
  });

  testWidgets('deleting a chofer removes them for good',
      (tester) async {
    setDesktopSize(tester);
    final backend = DemoBackend()..seed();
    final wilfredo = seedWilfredo(backend);
    await tester.pumpWidget(harness(backend));
    await tester.pumpAndSettle();
    await openRosterFor(tester, 'Wilfredo');

    await tester.tap(find.byTooltip('Eliminar'));
    await tester.pumpAndSettle();
    expect(find.text('¿Eliminar a Wilfredo Antonio Reyes?'), findsOneWidget);

    expect(find.textContaining('no se puede deshacer'), findsOneWidget);

    await tester.tap(find.text('Eliminar'));
    await tester.pumpAndSettle(const Duration(seconds: 2));

    // Gone, not archived: the cédula is free for a new registration.
    expect(backend.driver(wilfredo.id), isNull);
    expect(backend.allDrivers.any((d) => d.cedula == '40212345678'), isFalse);
    expect(find.text('Wilfredo Antonio Reyes'), findsNothing);
    expect(find.text('Wilfredo Antonio Reyes fue eliminado.'), findsOneWidget);
  });

  testWidgets('activating a new chofer clears them to work', (tester) async {
    setDesktopSize(tester);
    final backend = DemoBackend()..seed();
    final wilfredo = seedWilfredo(backend);
    expect(wilfredo.status, DriverStatus.inactive);
    await tester.pumpWidget(harness(backend));
    await tester.pumpAndSettle();
    await openRosterFor(tester, 'Wilfredo');

    // An inactive row offers activation, not suspension.
    expect(find.byTooltip('Suspender'), findsNothing);
    await tester.tap(find.byTooltip('Activar'));
    await tester.pumpAndSettle();

    expect(find.text('¿Activar a Wilfredo Antonio Reyes?'), findsOneWidget);
    // No grúa yet, which the office should hear about before, not after.
    expect(find.textContaining('No tiene grúa asignada'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, 'Activar'));
    await tester.pumpAndSettle(const Duration(seconds: 2));

    final active = backend.driver(wilfredo.id)!;
    expect(active.status, DriverStatus.active);
    // The "documentos pendientes" note the account opened with is gone.
    expect(active.statusReason, isEmpty);
    expect(
      find.text('Wilfredo Antonio Reyes ya puede trabajar.'),
      findsOneWidget,
    );
    expect(find.text('Activo'), findsOneWidget);
    expect(find.byTooltip('Suspender'), findsOneWidget);
  });

  testWidgets('backing out of activation changes nothing', (tester) async {
    setDesktopSize(tester);
    final backend = DemoBackend()..seed();
    final wilfredo = seedWilfredo(backend);
    await tester.pumpWidget(harness(backend));
    await tester.pumpAndSettle();
    await openRosterFor(tester, 'Wilfredo');

    await tester.tap(find.byTooltip('Activar'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancelar'));
    await tester.pumpAndSettle(const Duration(seconds: 2));

    expect(backend.driver(wilfredo.id)!.status, DriverStatus.inactive);
  });

  testWidgets('suspending a chofer requires the reason they will read',
      (tester) async {
    setDesktopSize(tester);
    final backend = DemoBackend()..seed();
    final wilfredo = seedWilfredo(backend);
    backend.setDriverStatus(wilfredo.id, DriverStatus.active);
    await tester.pumpWidget(harness(backend));
    await tester.pumpAndSettle();
    await openRosterFor(tester, 'Wilfredo');

    await tester.tap(find.byTooltip('Suspender'));
    await tester.pumpAndSettle();
    expect(find.text('¿Suspender a Wilfredo Antonio Reyes?'), findsOneWidget);

    // Without a reason the chofer would see a bare "cuenta suspendida".
    await tester.tap(find.widgetWithText(TextButton, 'Suspender'));
    await tester.pumpAndSettle();
    expect(find.text('Escribe el motivo de la suspensión.'), findsOneWidget);
    expect(backend.driver(wilfredo.id)!.status, DriverStatus.active);

    await tester.enterText(
      find.byType(TextFormField).last,
      'Efectivo pendiente de entregar',
    );
    await tester.tap(find.widgetWithText(TextButton, 'Suspender'));
    await tester.pumpAndSettle(const Duration(seconds: 2));

    final suspended = backend.driver(wilfredo.id)!;
    expect(suspended.status, DriverStatus.suspended);
    expect(suspended.statusReason, 'Efectivo pendiente de entregar');
    expect(suspended.isOnline, isFalse);
    expect(find.text('Wilfredo Antonio Reyes fue suspendido.'), findsOneWidget);
    expect(find.byTooltip('Activar'), findsOneWidget);
  });

  testWidgets('the details dialog offers every other status', (tester) async {
    setDesktopSize(tester);
    final backend = DemoBackend()..seed();
    final wilfredo = seedWilfredo(backend);
    await tester.pumpWidget(harness(backend));
    await tester.pumpAndSettle();
    await openRosterFor(tester, 'Wilfredo');

    await tester.tap(find.byTooltip('Ver'));
    await tester.pumpAndSettle();

    // Inactive already, so that is the one not offered.
    expect(find.widgetWithText(OutlinedButton, 'Activar'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, 'Suspender'), findsOneWidget);
    expect(find.text('Marcar inactivo'), findsNothing);

    await tester.tap(find.widgetWithText(OutlinedButton, 'Activar'));
    await tester.pumpAndSettle();
    // The details close and the confirmation takes their place.
    expect(find.text('L-884213'), findsNothing);
    await tester.tap(find.widgetWithText(TextButton, 'Activar'));
    await tester.pumpAndSettle(const Duration(seconds: 2));

    expect(backend.driver(wilfredo.id)!.status, DriverStatus.active);
  });

  testWidgets('a chofer who opens the app turns green on the roster',
      (tester) async {
    setDesktopSize(tester);
    final backend = DemoBackend()..seed();
    final wilfredo = seedWilfredo(backend);
    await tester.pumpWidget(harness(backend));
    await tester.pumpAndSettle();
    await openRosterFor(tester, 'Wilfredo');

    // Presence lives on the avatar's dot, named by its tooltip.
    expect(find.byTooltip('Desconectado'), findsOneWidget);

    // The driver app signing in, with the online switch still off.
    backend.setAppOpen(wilfredo.id, open: true);
    await tester.pumpAndSettle();
    expect(find.byTooltip('Conectado'), findsOneWidget);
    expect(find.byTooltip('Desconectado'), findsNothing);
    // The status column holds the account status and nothing else.
    expect(find.text('Conectado'), findsNothing);

    // Signing out, or closing the tab.
    backend.setAppOpen(wilfredo.id, open: false);
    await tester.pumpAndSettle();
    expect(find.byTooltip('Desconectado'), findsOneWidget);
  });

  // -------------------------------------------------------------------------
  // Fleet
  // -------------------------------------------------------------------------

  Future<void> openFleet(WidgetTester tester) async {
    await signIn(tester);
    await tester.tap(find.text('Grúas').last);
    await tester.pumpAndSettle();
  }

  /// The card showing [plate], so its buttons are the ones tapped.
  Finder cardFor(String plate) => find.ancestor(
        of: find.text(plate),
        matching: find.byType(FloatingCard),
      );

  /// Fills every required field of the grúa form.
  Future<void> fillTruckForm(WidgetTester tester, {required String plate}) async {
    await tester.enterText(find.widgetWithText(TextFormField, 'L123456'), plate);
    // The field, not its hint: the hint's own box does not take the tap.
    await tester.tap(find.byType(DropdownButtonFormField<TruckType>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Plataforma').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, 'Ford'), 'Isuzu');
    await tester.enterText(find.widgetWithText(TextFormField, 'F-450'), 'NQR');
    await tester.enterText(find.widgetWithText(TextFormField, '4500'), '5000');
    await tester.pumpAndSettle();

    // Both expiries are date pickers: open each and take the default a year
    // out. The first one filled stops reading 'dd/mm/aaaa', so `.first` walks
    // through them in order.
    for (var i = 0; i < 2; i++) {
      await tester.ensureVisible(find.text('dd/mm/aaaa').first);
      await tester.tap(find.text('dd/mm/aaaa').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('ACEPTAR'));
      await tester.pumpAndSettle();
    }
  }

  testWidgets('"Nueva grúa" opens a form that adds the grúa to the fleet',
      (tester) async {
    setDesktopSize(tester);
    final backend = DemoBackend()..seed();
    await tester.pumpWidget(harness(backend));
    await tester.pumpAndSettle();
    await openFleet(tester);
    expect(find.text('5 en la flota'), findsOneWidget);

    await tester.tap(find.text('Nueva grúa'));
    await tester.pumpAndSettle();
    expect(find.text('Crear grúa'), findsOneWidget);

    // Typed the way it might be read off the metal.
    await fillTruckForm(tester, plate: 'l-777 888');
    await tester.tap(find.text('Crear grúa'));
    await tester.pumpAndSettle(const Duration(seconds: 2));

    final created =
        backend.allTrucks.singleWhere((t) => t.plate == 'L777888');
    expect(created.make, 'Isuzu');
    expect(created.type, TruckType.plataforma);
    expect(created.capacityKg, 5000);
    expect(created.insuranceExpiry, isNotNull);
    expect(created.marbeteExpiry, isNotNull);
    expect(created.isAssigned, isFalse);

    // The form closed and the grid picked the new grúa up live.
    expect(find.text('Crear grúa'), findsNothing);
    expect(find.text('Grúa L777888 agregada a la flota.'), findsOneWidget);
    expect(find.text('6 en la flota'), findsOneWidget);
    expect(find.text('L777888'), findsOneWidget);
  });

  testWidgets('the grúa form refuses a bad plate and missing dates',
      (tester) async {
    setDesktopSize(tester);
    final backend = DemoBackend()..seed();
    await tester.pumpWidget(harness(backend));
    await tester.pumpAndSettle();
    await openFleet(tester);
    await tester.tap(find.text('Nueva grúa'));
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextFormField, 'L123456'), '12');
    await tester.tap(find.text('Crear grúa'));
    await tester.pumpAndSettle();

    expect(
      find.text('Esa placa no es válida. Ejemplo: L123456.'),
      findsOneWidget,
    );
    expect(find.text('Escoge el tipo de grúa.'), findsOneWidget);
    // One under each empty date field: seguro and marbete.
    expect(find.text('Escoge la fecha.'), findsNWidgets(2));
    expect(backend.allTrucks, hasLength(5));
  });

  testWidgets('a plate already in the fleet is refused', (tester) async {
    setDesktopSize(tester);
    final backend = DemoBackend()..seed();
    await tester.pumpWidget(harness(backend));
    await tester.pumpAndSettle();
    await openFleet(tester);
    await tester.tap(find.text('Nueva grúa'));
    await tester.pumpAndSettle();

    // A123456 is seeded.
    await fillTruckForm(tester, plate: 'A123456');
    await tester.tap(find.text('Crear grúa'));
    await tester.pumpAndSettle(const Duration(seconds: 2));

    expect(find.text('Ya existe una grúa con esa placa.'), findsOneWidget);
    expect(backend.allTrucks, hasLength(5));
  });

  testWidgets('a tap outside closes an untouched grúa form', (tester) async {
    setDesktopSize(tester);
    final backend = DemoBackend()..seed();
    await tester.pumpWidget(harness(backend));
    await tester.pumpAndSettle();
    await openFleet(tester);
    await tester.tap(find.text('Nueva grúa'));
    await tester.pumpAndSettle();

    // The barrier: the top-left corner is outside a dialog this size.
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    expect(find.text('Crear grúa'), findsNothing);
  });

  testWidgets('a tap outside a filled-in grúa form asks before closing',
      (tester) async {
    setDesktopSize(tester);
    final backend = DemoBackend()..seed();
    await tester.pumpWidget(harness(backend));
    await tester.pumpAndSettle();
    await openFleet(tester);
    await tester.tap(find.text('Nueva grúa'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, 'L123456'),
      'L777888',
    );

    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    // Still there, with the question over it.
    expect(find.text('¿Descartar la grúa?'), findsOneWidget);
    await tester.tap(find.text('Seguir editando'));
    await tester.pumpAndSettle();
    expect(find.text('Crear grúa'), findsOneWidget);
    expect(find.widgetWithText(TextFormField, 'L777888'), findsOneWidget);

    // And discarding takes the whole form with it.
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Descartar'));
    await tester.pumpAndSettle();
    expect(find.text('Crear grúa'), findsNothing);
    expect(backend.allTrucks, hasLength(5));
  });

  testWidgets('editing a grúa saves the changes', (tester) async {
    setDesktopSize(tester);
    final backend = DemoBackend()..seed();
    await tester.pumpWidget(harness(backend));
    await tester.pumpAndSettle();
    await openFleet(tester);

    await tester.tap(
      find.descendant(of: cardFor('A345678'), matching: find.byTooltip('Editar')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Editar grúa'), findsOneWidget);
    // Pre-filled from the record.
    expect(find.widgetWithText(TextFormField, 'Chevrolet'), findsOneWidget);

    await tester.enterText(
      find.widgetWithText(TextFormField, 'Chevrolet'),
      'GMC',
    );
    await tester.tap(find.text('Guardar cambios'));
    await tester.pumpAndSettle(const Duration(seconds: 2));

    expect(backend.truck('truck-3')!.make, 'GMC');
    expect(find.text('Cambios guardados.'), findsOneWidget);
  });

  testWidgets('deleting a grúa takes it off the fleet and frees its chofer',
      (tester) async {
    setDesktopSize(tester);
    final backend = DemoBackend()..seed();
    await tester.pumpWidget(harness(backend));
    await tester.pumpAndSettle();
    await openFleet(tester);

    await tester.tap(
      find.descendant(
        of: cardFor('A345678'),
        matching: find.byTooltip('Eliminar'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('¿Eliminar la grúa A345678?'), findsOneWidget);
    // Says who is left without a grúa, before it happens.
    expect(find.textContaining('Wilkin Rosario queda sin grúa'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, 'Eliminar'));
    await tester.pumpAndSettle(const Duration(seconds: 2));

    expect(backend.truck('truck-3')!.archived, isTrue);
    expect(backend.driver('driver-3')!.assignedTruckId, isNull);
    expect(find.text('A345678'), findsNothing);
    expect(find.text('4 en la flota'), findsOneWidget);
    expect(find.text('Grúa A345678 eliminada.'), findsOneWidget);
  });

  // -------------------------------------------------------------------------
  // Servicios
  // -------------------------------------------------------------------------

  Future<void> openServices(WidgetTester tester) async {
    await signIn(tester);
    await tester.tap(find.text('Servicios').last);
    await tester.pumpAndSettle(const Duration(seconds: 1));
  }

  /// Picks [option] from the dropdown currently showing [current].
  Future<void> choose(WidgetTester tester, String current, String option) async {
    await tester.tap(find.text(current).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text(option).last);
    await tester.pumpAndSettle(const Duration(seconds: 1));
  }

  testWidgets('"Servicios" is the list of every job, not the live map',
      (tester) async {
    setDesktopSize(tester);
    await tester.pumpWidget(harness(DemoBackend()..seed()));
    await tester.pumpAndSettle();
    await openServices(tester);

    expect(find.text('CÓDIGO'), findsOneWidget);
    // The map's panel is Operaciones', not this page's.
    expect(find.text('Solicitudes'), findsNothing);
    // The four seeded jobs, all within the default 30 days, all closed — in
    // the office's words, not the customer's.
    expect(find.text('Cerrado'), findsNWidgets(4));
    expect(find.text('Servicio cerrado'), findsNothing);
    expect(find.text('Ramón Peña'), findsNWidgets(4));
  });

  testWidgets('the period and status filters narrow the list on the server',
      (tester) async {
    setDesktopSize(tester);
    await tester.pumpWidget(harness(DemoBackend()..seed()));
    await tester.pumpAndSettle();
    await openServices(tester);

    // The newest seeded job is two days old.
    await choose(tester, 'Últimos 30 días', 'Últimos 7 días');
    expect(find.text('Cerrado'), findsOneWidget);

    await choose(tester, 'Últimos 7 días', 'Hoy');
    expect(find.text('Sin servicios'), findsOneWidget);

    await choose(tester, 'Hoy', 'Todo');
    expect(find.text('Cerrado'), findsNWidgets(4));

    await choose(tester, 'Todos', 'Cancelados');
    expect(find.text('Ningún servicio coincide con esos filtros.'), findsOneWidget);
  });

  testWidgets('a row opens the whole record of the job', (tester) async {
    setDesktopSize(tester);
    final backend = DemoBackend()..seed();
    final newest = backend.service('svc-history-0')!;
    await tester.pumpWidget(harness(backend));
    await tester.pumpAndSettle();
    await openServices(tester);

    await tester.tap(find.text(newest.code));
    await tester.pumpAndSettle();

    // The dialog repeats the code in its header, beside the row it covers.
    expect(find.text(newest.code), findsNWidgets(2));
    // Inside the dialog: the table behind it has a CLIENTE column too.
    final dialog = find.byType(Dialog);
    for (final section in ['CLIENTE', 'VEHÍCULO', 'PRECIO FINAL', 'PAGO', 'TIEMPOS']) {
      expect(
        find.descendant(of: dialog, matching: find.text(section)),
        findsOneWidget,
        reason: 'missing $section',
      );
    }
    expect(find.text(newest.totalCents.formatDOP), findsWidgets);
    // The strip across the top answers the four everyday questions before
    // anybody scrolls into the record itself.
    final tiles = <Rect>[];
    for (final tile in [
      'TOTAL',
      'FORMA DE PAGO',
      'DISTANCIA Y TIEMPO',
      'CHOFER ASIGNADO',
    ]) {
      final label = find.descendant(of: dialog, matching: find.text(tile));
      expect(label, findsOneWidget, reason: 'missing $tile');
      tiles.add(
        tester.getRect(
          find.ancestor(of: label, matching: find.byType(Container)).first,
        ),
      );
    }
    // One band, not four cards of different heights: a tile with no second
    // line under its figure is the same box as the ones that have one.
    expect(tiles.map((t) => t.height).toSet(), hasLength(1));
    expect(tiles.map((t) => t.top).toSet(), hasLength(1));
    expect(find.byKey(const Key('copy-service-code')), findsOneWidget);

    // Copying says so at the top middle of the window, not in a black bar
    // across the bottom corner.
    await tester.tap(find.byKey(const Key('copy-service-code')));
    await tester.pumpAndSettle();
    expect(find.text('Código copiado'), findsOneWidget);
    final card = tester.getRect(
      find
          .ancestor(
            of: find.byIcon(Icons.check_circle_outline),
            matching: find.byType(Container),
          )
          .first,
    );
    final window = tester.view.physicalSize / tester.view.devicePixelRatio;
    expect(card.top, lessThan(window.height / 3));
    expect(
      (card.center.dx - window.width / 2).abs(),
      lessThan(2),
      reason: 'the toast should be centred',
    );
    expect(card.width, lessThan(window.width / 2));
    // A finished job has nothing to act on in Operaciones.
    expect(find.text('Ver en Operaciones'), findsNothing);
  });

  testWidgets('a code typed with Enter opens that job', (tester) async {
    setDesktopSize(tester);
    final backend = DemoBackend()..seed();
    final oldest = backend.service('svc-history-3')!;
    await tester.pumpWidget(harness(backend));
    await tester.pumpAndSettle();
    await openServices(tester);

    await tester.enterText(
      find.widgetWithText(TextField, 'Código, teléfono, cliente, chofer o placa'),
      oldest.code.toLowerCase(),
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(find.text('PRECIO FINAL'), findsOneWidget);
    expect(find.text(oldest.code), findsWidgets);
  });

  testWidgets('a phone number narrows the list however it is typed',
      (tester) async {
    setDesktopSize(tester);
    await tester.pumpWidget(harness(DemoBackend()..seed()));
    await tester.pumpAndSettle();
    await openServices(tester);

    await tester.enterText(
      find.widgetWithText(TextField, 'Código, teléfono, cliente, chofer o placa'),
      '809-555-1234',
    );
    await tester.pumpAndSettle();
    expect(find.text('Cerrado'), findsNWidgets(4));

    await tester.enterText(
      find.widgetWithText(TextField, 'Código, teléfono, cliente, chofer o placa'),
      '849-000',
    );
    await tester.pumpAndSettle();
    expect(find.text('Sin resultados'), findsOneWidget);
  });

  testWidgets('the top bar search lands on Servicios with the search applied',
      (tester) async {
    setDesktopSize(tester);
    await tester.pumpWidget(harness(DemoBackend()..seed()));
    await tester.pumpAndSettle();
    await signIn(tester);

    await tester.enterText(
      find.widgetWithText(TextField, 'Buscar código, teléfono, chofer o placa…'),
      'Ramón',
    );
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(find.text('CÓDIGO'), findsOneWidget);
    expect(find.text('4 de 4 cargados'), findsOneWidget);
  });

  testWidgets('Efectivo shows the cash a chofer holds, and a corte takes it in',
      (tester) async {
    setDesktopSize(tester);
    final backend = DemoBackend(dispatchDelay: const Duration(hours: 1))..seed();

    // A cash job, collected by its chofer.
    final service = backend.createService(
      clientId: 'demo-client-1',
      pickup: const ServiceLocation(geo: LatLng(18.4795, -69.9420), address: 'Gazcue'),
      dropoff: const ServiceLocation(geo: LatLng(18.5001, -69.8800)),
      vehicle: const ServiceVehicle(make: 'Toyota', model: 'Corolla'),
      truckType: TruckType.gancho,
      quote: const Quote(totalCents: 250000),
      route: const ServiceRoute(distanceMeters: 8000),
    );
    final driver = backend.allDrivers
        .firstWhere((d) => d.truckType == TruckType.gancho && d.status.canWork && !d.isBusy);
    expect(backend.assignServiceManually(serviceId: service.id, driverId: driver.id), isNull);
    for (final (to, event) in [
      (ServiceStatus.arrived, ServiceEventName.markArrived),
      (ServiceStatus.inProgress, ServiceEventName.startService),
      (ServiceStatus.completed, ServiceEventName.completeService),
    ]) {
      backend.transition(service.id, to, event, driver.id, UserRole.driver);
    }
    backend.confirmCashCollected(service.id, driver.id, 250000);
    final holding = backend.driver(driver.id)!.cashOnHandCents;

    await tester.pumpWidget(harness(backend));
    await tester.pumpAndSettle();
    await signIn(tester);

    await tester.tap(find.text('Efectivo').first);
    await tester.pumpAndSettle();

    expect(find.byKey(Key('settle-${driver.id}')), findsOneWidget);
    expect(find.text(holding.formatDOP), findsWidgets);

    await tester.tap(find.byKey(Key('settle-${driver.id}')));
    await tester.pumpAndSettle();
    // The jobs the corte is made of are listed before anything is recorded.
    expect(find.text('Total a recibir'), findsOneWidget);

    await tester.tap(find.byKey(const Key('confirm-settle')));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(backend.driver(driver.id)!.cashOnHandCents, 0);
    expect(backend.cashSettlements(driverId: driver.id), hasLength(1));
    expect(find.byKey(Key('settle-${driver.id}')), findsNothing);
    expect(find.textContaining('Corte registrado'), findsOneWidget);

    // The demo's dispatch timer, stopped inside the test body.
    await tester.pumpWidget(const SizedBox());
    backend.dispose();
    await tester.pump();
  });

  testWidgets('a narrow window says so instead of reflowing', (tester) async {
    setWindow(tester, const Size(760, 900));

    await tester.pumpWidget(harness(DemoBackend()..seed()));
    await tester.pumpAndSettle();
    await signIn(tester);

    expect(find.text('Pantalla muy pequeña'), findsOneWidget);
  });

  testWidgets('every office page fits the narrowest window the panel allows',
      (tester) async {
    setWindow(tester, const Size(1024, 768));
    final backend = DemoBackend()
      ..seed()
      ..seedInsurerHistory();
    await tester.pumpWidget(harness(backend));
    await tester.pumpAndSettle();
    await signIn(tester);

    for (final page in [
      'Operaciones',
      'Servicios',
      'Clientes',
      'Choferes',
      'Grúas',
      'Efectivo',
      'Aseguradoras',
      'Cortes',
      'Facturación',
      'Reportes',
    ]) {
      await tester.tap(find.text(page).last);
      await tester.pumpAndSettle(const Duration(milliseconds: 500));
      expect(tester.takeException(), isNull, reason: page);
    }
    backend.dispose();
    await tester.pump();
  });

  // -------------------------------------------------------------------------
  // Licence verification
  // -------------------------------------------------------------------------

  /// A chofer who registered from the app, with both sides of the licence up
  /// and the automatic check run.
  Driver seedSelfRegistered(DemoBackend backend) {
    final driver = backend.createDriver(
      name: 'Yulissa Marte Peña',
      cedula: '40298765432',
      phone: '+18095551111',
      email: 'yulissa@gruasrd.do',
      licenseNumber: '40298765432',
      licenseExpiry: DateTime.now().add(const Duration(days: 400)),
      selfRegistered: true,
    )!;
    for (final type in [
      DriverDocumentType.licencia,
      DriverDocumentType.licenciaReverso,
    ]) {
      final path = 'drivers/${driver.id}/docs/${type.wire}.jpg';
      backend
        ..storeUpload(path, 'data:image/jpeg;base64,AAAA')
        ..attachDocument(
          driver.id,
          DriverDocument(type: type, storagePath: path),
        );
    }
    backend.verifyLicense(driver.id);
    return backend.driver(driver.id)!;
  }

  Future<void> openVerification(WidgetTester tester) async {
    await signIn(tester);
    await tester.tap(find.text('Verificación'));
    await tester.pumpAndSettle();
    // "Revisar" is the table's last column, past a sideways scroll in the
    // test font.
    if (find.text('Revisar').evaluate().isNotEmpty) {
      await tester.ensureVisible(find.text('Revisar'));
      await tester.pumpAndSettle();
    }
  }

  testWidgets('a verified licence waits in "Por activar" with a sidebar badge',
      (tester) async {
    setDesktopSize(tester);
    final backend = DemoBackend()..seed();
    final yulissa = seedSelfRegistered(backend);
    // One the office opened itself never goes through the check.
    seedWilfredo(backend);
    await tester.pumpWidget(harness(backend));
    await tester.pumpAndSettle();
    await openVerification(tester);

    expect(find.text('Por activar (1)'), findsOneWidget);
    expect(find.text(yulissa.name), findsOneWidget);
    expect(find.text('Wilfredo Antonio Reyes'), findsNothing);

    await tester.tap(find.text('Revisar'));
    await tester.pumpAndSettle();

    // Both sides and the profile photo, and every check that passed.
    expect(find.text('Frente'), findsOneWidget);
    expect(find.text('Reverso'), findsOneWidget);
    expect(find.text('La cédula coincide'), findsOneWidget);
    expect(find.text('Aprobar licencia'), findsNothing);
    expect(find.text('Activar chofer'), findsOneWidget);
  });

  testWidgets('the office activates a verified chofer from the review',
      (tester) async {
    setDesktopSize(tester);
    final backend = DemoBackend()..seed();
    final yulissa = seedSelfRegistered(backend);
    await tester.pumpWidget(harness(backend));
    await tester.pumpAndSettle();
    await openVerification(tester);
    await tester.tap(find.text('Revisar'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Activar chofer'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Activar'));
    await tester.pumpAndSettle(const Duration(seconds: 2));

    expect(backend.driver(yulissa.id)!.status, DriverStatus.active);
    expect(find.text('${yulissa.name} ya puede trabajar.'), findsOneWidget);
  });

  testWidgets('rejecting a licence needs a reason the chofer then reads',
      (tester) async {
    setDesktopSize(tester);
    final backend = DemoBackend()..seed();
    final yulissa = seedSelfRegistered(backend);
    await tester.pumpWidget(harness(backend));
    await tester.pumpAndSettle();
    await openVerification(tester);
    await tester.tap(find.text('Revisar'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Rechazar'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Rechazar'));
    await tester.pumpAndSettle();
    expect(find.text('Escribe el motivo del rechazo.'), findsOneWidget);

    await tester.enterText(
      find.byType(TextFormField).last,
      'La foto del reverso está cortada.',
    );
    await tester.tap(find.widgetWithText(TextButton, 'Rechazar'));
    await tester.pumpAndSettle(const Duration(seconds: 2));

    final check = backend.driver(yulissa.id)!.licenseVerification!;
    expect(check.state, LicenseVerificationState.rejected);
    expect(check.reason, 'La foto del reverso está cortada.');
    // A fresh set of tries for the new photos, and still not working.
    expect(check.attempts, 0);
    expect(backend.driver(yulissa.id)!.status, DriverStatus.inactive);
  });
}
