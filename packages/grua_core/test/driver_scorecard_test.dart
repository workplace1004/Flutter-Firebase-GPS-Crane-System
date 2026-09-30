import 'package:flutter_test/flutter_test.dart';
import 'package:grua_core/grua_core.dart';

/// How a chofer's record reads to the office.
void main() {
  Driver driver({
    int ratingSum = 0,
    int ratingCount = 0,
    Map<String, int> ratingTags = const {},
    Map<String, int> ratingStars = const {},
    int accepted = 0,
    int rejected = 0,
    int missed = 0,
    int offersSent = 0,
    int completed = 0,
    int cancellations = 0,
  }) =>
      Driver(
        id: 'd1',
        name: 'Carlos Méndez',
        ratingSum: ratingSum,
        ratingCount: ratingCount,
        ratingTags: ratingTags,
        ratingStars: ratingStars,
        offersAccepted: accepted,
        offersRejected: rejected,
        offersMissed: missed,
        offersSent: offersSent,
        completedServices: completed,
        cancellations: cancellations,
      );

  group('the figures', () {
    test('a chofer nobody has rated is new, not 4.8', () {
      final card = DriverScorecard.of(driver());
      expect(card.hasRatings, isFalse);
      expect(card.averageLabel, 'Nuevo');
      expect(card.standing, DriverStanding.newDriver);
      expect(card.acceptanceLabel, '—');
      expect(card.cancellationLabel, '—');
    });

    test('the average is what customers gave', () {
      final card = DriverScorecard.of(driver(ratingSum: 47, ratingCount: 10));
      expect(card.average, closeTo(4.7, 0.001));
      expect(card.averageLabel, '4.7');
    });

    test('acceptance counts rejected and missed offers', () {
      // The bug: dispatch never kept offersSent, so everyone read 100%.
      final d = driver(accepted: 6, rejected: 3, missed: 1);
      expect(d.offersReceived, 10);
      expect(d.acceptanceLabel, '60%');
      expect(DriverScorecard.of(d).acceptanceLabel, '60%');
    });

    test('stars and tags are counted, most frequent first', () {
      final card = DriverScorecard.of(
        driver(
          ratingSum: 13,
          ratingCount: 3,
          ratingStars: const {'5': 2, '3': 1},
          ratingTags: const {
            'punctual': 1,
            'careful': 2,
            'late': 1,
            'retired_tag': 4,
          },
        ),
      );
      expect(card.starCounts, [0, 0, 1, 0, 2]);
      expect(card.strengths, [
        (DriverRatingTag.careful, 2),
        (DriverRatingTag.punctual, 1),
      ]);
      // A tag this app does not know is left out rather than miscounted.
      expect(card.complaints, [(DriverRatingTag.late, 1)]);
    });
  });

  group('the standing', () {
    test('one bad rating does not judge a new chofer', () {
      final card = DriverScorecard.of(driver(ratingSum: 1, ratingCount: 1));
      expect(card.standing, DriverStanding.newDriver);
      expect(card.reasons, isEmpty);
    });

    test('a slipping average puts them under watch, a poor one is critical',
        () {
      final watch = DriverScorecard.of(driver(ratingSum: 40, ratingCount: 10));
      expect(watch.standing, DriverStanding.watch);
      expect(watch.reasons.single, contains('4.0'));

      final critical =
          DriverScorecard.of(driver(ratingSum: 30, ratingCount: 10));
      expect(critical.standing, DriverStanding.critical);
    });

    test('turning down offers and dropping jobs are watched', () {
      final picky = DriverScorecard.of(
        driver(accepted: 5, rejected: 5, missed: 2, completed: 20),
      );
      expect(picky.standing, DriverStanding.watch);
      expect(picky.reasons.single, 'Acepta el 42% de las ofertas');

      final dropping =
          DriverScorecard.of(driver(completed: 16, cancellations: 4));
      expect(dropping.standing, DriverStanding.watch);
      expect(dropping.reasons.single, 'Cancela el 20% de sus servicios');
    });

    test('a few offers are not enough to judge acceptance', () {
      final card = DriverScorecard.of(
        driver(accepted: 1, rejected: 4, completed: 12),
      );
      expect(card.standing, DriverStanding.good);
    });

    test('serious complaints count however good the average', () {
      final card = DriverScorecard.of(
        driver(
          ratingSum: 95,
          ratingCount: 20,
          ratingTags: const {'vehicle_damage': 1, 'overcharge': 1},
        ),
      );
      expect(card.seriousComplaints, 2);
      expect(card.standing, DriverStanding.watch);
      expect(card.reasons.single, contains('2 quejas graves'));
    });

    test('excellent takes a long, strong record', () {
      expect(
        DriverScorecard.of(
          driver(ratingSum: 98, ratingCount: 20, accepted: 18, rejected: 2),
        ).standing,
        DriverStanding.excellent,
      );
      // The same average over fewer ratings is only good.
      expect(
        DriverScorecard.of(driver(ratingSum: 49, ratingCount: 10)).standing,
        DriverStanding.good,
      );
    });
  });

  test('the tags offered follow the stars', () {
    expect(
      DriverRatingTag.forStars(5).every((t) => t.positive),
      isTrue,
    );
    expect(
      DriverRatingTag.forStars(3).any((t) => t.positive),
      isFalse,
    );
    expect(DriverRatingTag.forStars(1), contains(DriverRatingTag.vehicleDamage));
    expect(DriverRatingTag.forStars(4), isNot(contains(DriverRatingTag.unknown)));
  });
}
