import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grua_core/grua_core.dart';
import 'package:grua_testing/grua_testing.dart';

/// A customer rating their chofer, through the gateway, the way `rateService`
/// behaves: once, within the week, feeding the chofer's record and filing a
/// review the office sees.
void main() {
  late DemoBackend backend;
  late ProviderContainer container;

  // Finished two days ago, by driver-1, for the seeded customer.
  const recent = 'svc-history-0';
  // Finished nine days ago: past the week.
  const old = 'svc-history-1';

  setUp(() {
    backend = DemoBackend()..seed();
    container = ProviderContainer(overrides: demoOverrides(backend: backend));
  });

  tearDown(() {
    container.dispose();
    backend.dispose();
  });

  FunctionsGateway gateway() => container.read(functionsGatewayProvider);

  test('a rating lands on the service, the record and the office', () async {
    final driverId = backend.service(recent)!.driverId!;
    final before = backend.driver(driverId)!;

    final result = await gateway().rateService(
      serviceId: recent,
      stars: 5,
      tags: const [
        DriverRatingTag.punctual,
        DriverRatingTag.careful,
        // A complaint with five stars is dropped, as the server drops it.
        DriverRatingTag.late,
      ],
      comment: '  Muy amable  ',
    );
    expect(result.isOk, isTrue);

    final rating = backend.service(recent)!.ratings.clientToDriver!;
    expect(rating.stars, 5);
    expect(rating.comment, 'Muy amable');
    expect(rating.ratingTags, [DriverRatingTag.punctual, DriverRatingTag.careful]);

    final after = backend.driver(driverId)!;
    expect(after.ratingCount, before.ratingCount + 1);
    expect(after.ratingSum, before.ratingSum + 5);
    expect(after.ratingTags['careful'], 1);
    expect(after.recentFeedback.first.comment, 'Muy amable');

    final review = backend.review(recent)!;
    expect(review.driverId, driverId);
    expect(review.clientName, 'Ramón Peña');
    // Five stars and praise: nothing for the office to do.
    expect(review.status, DriverReviewStatus.ok);
  });

  test('a service is rated once', () async {
    expect((await gateway().rateService(serviceId: recent, stars: 4)).isOk, isTrue);
    final again = await gateway().rateService(serviceId: recent, stars: 1);
    expect(again.failureOrNull?.userMessage, contains('Ya calificaste'));
  });

  test('only for a week after the tow', () async {
    final late = await gateway().rateService(serviceId: old, stars: 5);
    expect(late.failureOrNull?.userMessage, contains('7 días'));
  });

  test('low stars and serious complaints wait for the office', () async {
    await gateway().rateService(
      serviceId: recent,
      stars: 3,
      tags: const [DriverRatingTag.overcharge],
      comment: 'Me pidió 500 pesos más',
    );
    expect(backend.review(recent)!.status, DriverReviewStatus.open);

    final open = await container
        .read(driverRepositoryProvider)
        .watchReviews(openOnly: true)
        .first;
    expect(open.map((r) => r.serviceId), [recent]);

    backend.currentUserId = 'admin-1';
    final empty = await gateway().resolveDriverReview(serviceId: recent, note: '');
    expect(empty.isErr, isTrue);

    final done = await gateway().resolveDriverReview(
      serviceId: recent,
      note: 'Se habló con el chofer y se devolvió el dinero.',
    );
    expect(done.isOk, isTrue);
    final resolved = backend.review(recent)!;
    expect(resolved.status, DriverReviewStatus.resolved);
    expect(resolved.resolutionNote, startsWith('Se habló'));

    // Closed once: a second close is refused.
    final twice = await gateway().resolveDriverReview(
      serviceId: recent,
      note: 'Otra vez',
    );
    expect(twice.isErr, isTrue);
  });
}
