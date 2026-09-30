import 'package:flutter_riverpod/flutter_riverpod.dart';
// Riverpod 3 keeps `Override` out of the default export surface.
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:grua_core/grua_core.dart';

import 'demo_backend.dart';
import 'demo_repositories.dart';

/// The in-memory backend a test is running against, for a test that wants to
/// reach past the repositories and inspect or drive it directly.
final demoBackendProvider = Provider<DemoBackend>((ref) {
  final backend = DemoBackend()..seed();
  ref.onDispose(backend.dispose);
  return backend;
});

/// Binds every repository to the in-memory backend.
///
/// Pass a pre-seeded [backend] to control the fixture, and [actingAs] to sign
/// in as somebody other than the seeded customer — the driver app runs the
/// same wiring as a chofer.
List<Override> demoOverrides({
  DemoBackend? backend,
  UserRole role = UserRole.client,
  String? actingAs,
  VoiceTransport Function()? voiceTransport,
}) {
  final instance = backend ?? (DemoBackend()..seed());
  if (actingAs != null) instance.currentUserId = actingAs;
  return [
    demoBackendProvider.overrideWithValue(instance),
    authRepositoryProvider.overrideWithValue(
      DemoAuthRepository(instance, role: role),
    ),
    userRepositoryProvider.overrideWithValue(DemoUserRepository(instance)),
    driverRepositoryProvider.overrideWithValue(DemoDriverRepository(instance)),
    truckRepositoryProvider.overrideWithValue(DemoTruckRepository(instance)),
    serviceRepositoryProvider.overrideWithValue(
      DemoServiceRepository(instance),
    ),
    offerRepositoryProvider.overrideWithValue(DemoOfferRepository(instance)),
    callRepositoryProvider.overrideWithValue(DemoCallRepository(instance)),
    // No LiveKit server in a test: calls ring and connect without audio.
    voiceTransportFactoryProvider.overrideWithValue(
      voiceTransport ?? SilentVoiceTransport.new,
    ),
    chatRepositoryProvider.overrideWithValue(DemoChatRepository(instance)),
    chatRequestRepositoryProvider.overrideWithValue(
      DemoChatRequestRepository(instance),
    ),
    typingRepositoryProvider.overrideWithValue(DemoTypingRepository(instance)),
    chatPrefsRepositoryProvider.overrideWithValue(
      DemoChatPrefsRepository(instance),
    ),
    earningsRepositoryProvider.overrideWithValue(
      DemoEarningsRepository(instance),
    ),
    invoiceRepositoryProvider.overrideWithValue(
      DemoInvoiceRepository(instance),
    ),
    insurerRepositoryProvider.overrideWithValue(
      DemoInsurerRepository(instance),
    ),
    configRepositoryProvider.overrideWithValue(DemoConfigRepository(instance)),
    functionsGatewayProvider.overrideWithValue(DemoFunctionsGateway(instance)),
  ];
}
