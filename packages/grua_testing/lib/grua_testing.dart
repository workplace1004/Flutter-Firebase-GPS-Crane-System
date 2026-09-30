/// An in-memory stand-in for the whole backend, for tests only.
///
/// It implements the real state machine, pricing and dispatch rules against
/// seeded fixtures, so widget tests walk real flows without a network. It
/// enforces nothing — any password signs in — which is why it lives here, as a
/// dev dependency, and no app can ship with it.
library;

export 'src/demo_backend.dart';
export 'src/demo_overrides.dart';
export 'src/demo_repositories.dart';
