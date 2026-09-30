import 'package:flutter/foundation.dart';

import 'enums.dart';
import 'models/driver.dart';

/// Where a chofer stands overall.
enum DriverStanding {
  /// Too little history to judge.
  newDriver('Nuevo'),
  excellent('Excelente'),
  good('Bueno'),

  /// Something is slipping: the office should talk to them.
  watch('En observación'),

  /// Customers are being badly served: act now.
  critical('Crítico');

  const DriverStanding(this.label);

  final String label;

  bool get needsAttention => this == watch || this == critical;
}

/// A chofer's evaluation, read off their record: what customers say, how they
/// answer offers, how often they drop a job, and what that adds up to.
///
/// Counts are over the chofer's whole history. Each judgment waits for enough
/// of it to mean something — one bad rating does not make a new chofer
/// "crítico".
@immutable
class DriverScorecard {
  const DriverScorecard._({
    required this.average,
    required this.ratingCount,
    required this.starCounts,
    required this.strengths,
    required this.complaints,
    required this.seriousComplaints,
    required this.offersReceived,
    required this.acceptanceRate,
    required this.completed,
    required this.cancellations,
    required this.standing,
    required this.reasons,
  });

  factory DriverScorecard.of(Driver driver) {
    final count = driver.ratingCount;
    final average = driver.averageRating;

    final starCounts = [
      for (var star = 1; star <= 5; star++) driver.ratingStars['$star'] ?? 0,
    ];

    List<(DriverRatingTag, int)> tally({required bool positive}) {
      final rows = [
        for (final MapEntry(:key, :value) in driver.ratingTags.entries)
          if (DriverRatingTag.fromWire(key) case final tag
              when tag != DriverRatingTag.unknown &&
                  tag.positive == positive &&
                  value > 0)
            (tag, value),
      ]..sort((a, b) => b.$2.compareTo(a.$2));
      return rows;
    }

    final complaints = tally(positive: false);
    final serious = complaints
        .where((c) => c.$1.serious && c.$1 != DriverRatingTag.rude)
        .fold(0, (sum, c) => sum + c.$2);

    final offers = driver.offersReceived;
    final acceptance = offers == 0 ? null : driver.acceptanceRate;
    final jobs = driver.completedServices + driver.cancellations;
    final cancelRate = jobs == 0 ? 0.0 : driver.cancellations / jobs;

    final critical = <String>[];
    final watch = <String>[];

    if (count >= minRatings) {
      final shown = average.toStringAsFixed(1);
      if (average < criticalAverage) {
        critical.add('Calificación promedio $shown');
      } else if (average < watchAverage) {
        watch.add('Calificación promedio $shown');
      }
    }
    if (serious > 0 && count > 0) {
      final share = serious / count;
      final line = serious == 1
          ? '1 queja grave (daño, cobro de más o manejo peligroso)'
          : '$serious quejas graves (daño, cobro de más o manejo peligroso)';
      if (serious >= 3 && share >= 0.1) {
        critical.add(line);
      } else if (share >= 0.05) {
        watch.add(line);
      }
    }
    if (acceptance != null && offers >= minOffers && acceptance < watchAcceptance) {
      watch.add('Acepta el ${(acceptance * 100).round()}% de las ofertas');
    }
    if (jobs >= minJobs && cancelRate > watchCancelRate) {
      watch.add('Cancela el ${(cancelRate * 100).round()}% de sus servicios');
    }

    final DriverStanding standing;
    if (critical.isNotEmpty) {
      standing = DriverStanding.critical;
    } else if (watch.isNotEmpty) {
      standing = DriverStanding.watch;
    } else if (count < minRatings && driver.completedServices < minJobs) {
      standing = DriverStanding.newDriver;
    } else if (count >= 20 &&
        average >= excellentAverage &&
        (acceptance == null || acceptance >= 0.85)) {
      standing = DriverStanding.excellent;
    } else {
      standing = DriverStanding.good;
    }

    return DriverScorecard._(
      average: average,
      ratingCount: count,
      starCounts: starCounts,
      strengths: tally(positive: true),
      complaints: complaints,
      seriousComplaints: serious,
      offersReceived: offers,
      acceptanceRate: acceptance,
      completed: driver.completedServices,
      cancellations: driver.cancellations,
      standing: standing,
      reasons: [...critical, ...watch],
    );
  }

  /// Ratings needed before the average counts against a chofer.
  static const minRatings = 5;

  /// Offers answered before the acceptance rate counts.
  static const minOffers = 10;

  /// Jobs taken before the cancellation rate counts.
  static const minJobs = 10;

  static const criticalAverage = 3.5;
  static const watchAverage = 4.2;
  static const excellentAverage = 4.8;
  static const watchAcceptance = 0.6;
  static const watchCancelRate = 0.15;

  /// The plain average, 0 before the first rating.
  final double average;
  final int ratingCount;

  /// Ratings per star: index 0 is one star, index 4 is five.
  final List<int> starCounts;

  /// Praise and complaints, most frequent first.
  final List<(DriverRatingTag, int)> strengths;
  final List<(DriverRatingTag, int)> complaints;

  /// Damage, overcharging and dangerous driving, together.
  final int seriousComplaints;

  final int offersReceived;

  /// Null before the first offer.
  final double? acceptanceRate;
  final int completed;
  final int cancellations;

  final DriverStanding standing;

  /// Why the standing is [DriverStanding.watch] or [DriverStanding.critical],
  /// most serious first. Empty otherwise.
  final List<String> reasons;

  bool get hasRatings => ratingCount > 0;

  /// "4.7" or "Nuevo".
  String get averageLabel => hasRatings ? average.toStringAsFixed(1) : 'Nuevo';

  String get acceptanceLabel => switch (acceptanceRate) {
        final rate? => '${(rate * 100).round()}%',
        null => '—',
      };

  double get cancellationRate {
    final jobs = completed + cancellations;
    return jobs == 0 ? 0 : cancellations / jobs;
  }

  String get cancellationLabel =>
      completed + cancellations == 0 ? '—' : '${(cancellationRate * 100).round()}%';
}
