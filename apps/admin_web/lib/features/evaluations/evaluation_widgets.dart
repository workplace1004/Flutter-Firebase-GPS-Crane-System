import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// Riverpod 3 keeps the family types out of the default export surface.
import 'package:flutter_riverpod/misc.dart' show StreamProviderFamily;
import 'package:grua_core/grua_core.dart';

/// The reviews waiting for the office, newest first.
final openReviewsProvider = StreamProvider<List<DriverReview>>(
  (ref) => ref
      .watch(driverRepositoryProvider)
      .watchReviews(openOnly: true, limit: 200),
);

/// The latest reviews of every chofer.
final recentReviewsProvider = StreamProvider<List<DriverReview>>(
  (ref) => ref.watch(driverRepositoryProvider).watchReviews(limit: 100),
);

/// One chofer's latest reviews.
final StreamProviderFamily<List<DriverReview>, String> driverReviewsProvider =
    StreamProvider.family<List<DriverReview>, String>(
  (ref, driverId) => ref
      .watch(driverRepositoryProvider)
      .watchReviews(driverId: driverId, limit: 5),
);

/// Where a chofer stands, coloured by how urgently the office should act.
class DriverStandingChip extends StatelessWidget {
  const DriverStandingChip({required this.standing, super.key});

  final DriverStanding standing;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final (fg, bg) = switch (standing) {
      DriverStanding.critical => (palette.danger, palette.dangerTint),
      DriverStanding.watch => (palette.warning, palette.warningTint),
      DriverStanding.excellent => (palette.success, palette.successTint),
      DriverStanding.good || DriverStanding.newDriver => (
          palette.textMuted,
          palette.surfaceSubtle,
        ),
    };
    return Container(
      key: Key('standing-${standing.name}'),
      padding: const EdgeInsets.symmetric(horizontal: Insets.sm, vertical: 2),
      decoration: BoxDecoration(color: bg, borderRadius: Corners.brSm),
      child: Text(
        standing.label,
        style: Theme.of(context).textTheme.labelMedium?.copyWith(color: fg),
      ),
    );
  }
}

/// Stars as icons, for a rating read at a glance.
class StarsLine extends StatelessWidget {
  const StarsLine({required this.stars, this.size = 16, super.key});

  final int stars;
  final double size;

  @override
  Widget build(BuildContext context) => Semantics(
        label: stars == 1 ? '1 estrella' : '$stars estrellas',
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var star = 1; star <= 5; star++)
              Icon(
                star <= stars ? Icons.star_rounded : Icons.star_outline_rounded,
                size: size,
                color: star <= stars
                    ? context.palette.warning
                    : context.palette.textFaint,
              ),
          ],
        ),
      );
}

/// An average as five stars, halves included: 4.3 draws four and a half.
class RatingStars extends StatelessWidget {
  const RatingStars({required this.value, this.size = 16, super.key});

  final double value;
  final double size;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    // To the nearest half star.
    final halves = (value * 2).round();
    return Semantics(
      label: '${value.toStringAsFixed(1)} de 5 estrellas',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var star = 1; star <= 5; star++)
            Icon(
              halves >= star * 2
                  ? Icons.star_rounded
                  : halves == star * 2 - 1
                      ? Icons.star_half_rounded
                      : Icons.star_outline_rounded,
              size: size,
              color: halves >= star * 2 - 1 ? palette.warning : palette.textFaint,
            ),
        ],
      ),
    );
  }
}

/// A tag a customer gave, green for praise and red for a complaint.
class RatingTagChip extends StatelessWidget {
  const RatingTagChip({required this.tag, this.count, super.key});

  final DriverRatingTag tag;
  final int? count;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final (fg, bg) = tag.positive
        ? (palette.success, palette.successTint)
        : (palette.danger, palette.dangerTint);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Insets.sm, vertical: 2),
      decoration: BoxDecoration(color: bg, borderRadius: Corners.brSm),
      child: Text(
        count == null ? tag.label : '${tag.label} · $count',
        style: Theme.of(context).textTheme.labelMedium?.copyWith(color: fg),
      ),
    );
  }
}

/// A chofer's evaluation, for the details dialog: standing and why, what
/// customers give them, how they work, and the latest reviews.
class DriverScorecardView extends ConsumerWidget {
  const DriverScorecardView({required this.driver, super.key});

  final Driver driver;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final card = DriverScorecard.of(driver);
    final reviews = ref.watch(driverReviewsProvider(driver.id)).value ?? const [];
    final text = Theme.of(context).textTheme;
    final palette = context.palette;
    final maxStars = card.starCounts.fold(0, (a, b) => a > b ? a : b);

    Widget figure(String label, String value, {Color? color, Key? key}) =>
        Expanded(
          child: Column(
            key: key,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                value,
                style: text.titleLarge?.copyWith(color: color),
              ),
              Text(
                label,
                style: text.bodySmall?.copyWith(color: palette.textMuted),
              ),
            ],
          ),
        );

    return Column(
      key: const Key('driver-scorecard'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            DriverStandingChip(standing: card.standing),
            const Spacer(),
            if (card.hasRatings) StarsLine(stars: card.average.round()),
          ],
        ),
        for (final reason in card.reasons)
          Padding(
            padding: const EdgeInsets.only(top: Insets.xs),
            child: Row(
              children: [
                Icon(Icons.error_outline, size: 16, color: palette.danger),
                const SizedBox(width: Insets.xs),
                Expanded(child: Text(reason, style: text.bodySmall)),
              ],
            ),
          ),
        const SizedBox(height: Insets.md),
        Row(
          children: [
            figure(
              card.hasRatings
                  ? '${card.ratingCount} ${card.ratingCount == 1 ? 'calificación' : 'calificaciones'}'
                  : 'Sin calificaciones',
              card.averageLabel,
              key: const Key('scorecard-average'),
            ),
            figure(
              'Acepta (${card.offersReceived} ofertas)',
              card.acceptanceLabel,
              key: const Key('scorecard-acceptance'),
              color: (card.acceptanceRate ?? 1) < DriverScorecard.watchAcceptance &&
                      card.offersReceived >= DriverScorecard.minOffers
                  ? palette.danger
                  : null,
            ),
            figure(
              'Cancela (${card.cancellations} de ${card.completed + card.cancellations})',
              card.cancellationLabel,
              key: const Key('scorecard-cancellations'),
            ),
          ],
        ),
        if (card.hasRatings) ...[
          const SizedBox(height: Insets.md),
          for (var star = 5; star >= 1; star--)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 1),
              child: Row(
                children: [
                  SizedBox(
                    width: 28,
                    child: Text('$star ★', style: text.bodySmall),
                  ),
                  Expanded(
                    child: ClipRRect(
                      borderRadius: Corners.brXs,
                      child: LinearProgressIndicator(
                        value: maxStars == 0
                            ? 0
                            : card.starCounts[star - 1] / maxStars,
                        minHeight: 6,
                        color: palette.warning,
                        backgroundColor: palette.surfaceSubtle,
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 36,
                    child: Text(
                      '${card.starCounts[star - 1]}',
                      textAlign: TextAlign.end,
                      style: text.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
        ],
        if (card.strengths.isNotEmpty || card.complaints.isNotEmpty) ...[
          const SizedBox(height: Insets.md),
          Wrap(
            spacing: Insets.xs,
            runSpacing: Insets.xs,
            children: [
              for (final (tag, count) in [...card.complaints, ...card.strengths])
                RatingTagChip(tag: tag, count: count),
            ],
          ),
        ],
        if (reviews.isNotEmpty) ...[
          const SizedBox(height: Insets.md),
          Text('Últimas evaluaciones', style: text.titleSmall),
          for (final review in reviews)
            Padding(
              padding: const EdgeInsets.only(top: Insets.sm),
              child: ReviewSummary(review: review),
            ),
        ],
      ],
    );
  }
}

/// One review in a line or two: stars, when, which job, and what was said.
class ReviewSummary extends StatelessWidget {
  const ReviewSummary({required this.review, this.showDriver = false, super.key});

  final DriverReview review;

  /// On the page that lists every chofer's reviews.
  final bool showDriver;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final palette = context.palette;
    final meta = [
      if (showDriver && review.driverName.isNotEmpty) review.driverName,
      if (review.serviceCode.isNotEmpty) review.serviceCode,
      if (review.clientName.isNotEmpty) 'de ${review.clientName}',
      if (review.ratedAt case final at?) DoTime.dateAndTime(at),
    ].join(' · ');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            StarsLine(stars: review.stars, size: 14),
            const SizedBox(width: Insets.sm),
            Expanded(
              child: Text(
                meta,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: text.bodySmall?.copyWith(color: palette.textMuted),
              ),
            ),
          ],
        ),
        if (review.ratingTags.isNotEmpty) ...[
          const SizedBox(height: Insets.xxs),
          Wrap(
            spacing: Insets.xs,
            runSpacing: Insets.xxs,
            children: [
              for (final tag in review.ratingTags) RatingTagChip(tag: tag),
            ],
          ),
        ],
        if (review.comment.isNotEmpty) ...[
          const SizedBox(height: Insets.xxs),
          Text('“${review.comment}”', style: text.bodyMedium),
        ],
      ],
    );
  }
}
