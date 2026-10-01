import 'enums.dart';
import 'models/service.dart';

/// How long after the tow either side may rate it. `rateService` holds the
/// same line.
const ratingWindow = Duration(days: 7);

bool _ratable(Service service, DateTime now) {
  final finished = service.status == ServiceStatus.completed ||
      service.status == ServiceStatus.closed;
  if (!finished || !service.hasDriver) return false;
  final at = service.timeline.completedAt;
  return at == null || now.difference(at) <= ratingWindow;
}

/// Whether the customer can still rate this service's chofer: their own
/// finished tow, not yet rated, within [ratingWindow].
///
/// An insurance company's tow is not rated from the customer app: the
/// insured has no account in it.
bool canRateDriver(Service service, DateTime now) =>
    _ratable(service, now) &&
    !service.isInsurerJob &&
    !(service.ratings.clientToDriver?.isRated ?? false);

/// Whether the chofer can still rate this service's customer: a finished job
/// for somebody with an account, not yet rated, within [ratingWindow].
bool canRateClient(Service service, DateTime now) =>
    _ratable(service, now) &&
    !service.isInsurerJob &&
    service.clientId.isNotEmpty &&
    !(service.ratings.driverToClient?.isRated ?? false);

/// The most recent service in [history] still waiting for a rating, by
/// [canRate]. [history] is newest first, as `fetchHistory` returns it.
Service? latestUnrated(
  Iterable<Service> history,
  DateTime now,
  bool Function(Service service, DateTime now) canRate,
) {
  for (final service in history) {
    if (canRate(service, now)) return service;
  }
  return null;
}
