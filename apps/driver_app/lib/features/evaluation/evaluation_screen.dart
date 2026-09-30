import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:grua_core/grua_core.dart';

/// What customers say about the chofer, and how the office reads it.
///
/// Everything comes off the chofer's own record. The reviews carry no service,
/// customer or date — the office has those; the chofer gets what they can
/// learn from, not who to call about it.
class EvaluationScreen extends ConsumerWidget {
  const EvaluationScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final driver = ref.watch(currentDriverProvider).value;
    final text = Theme.of(context).textTheme;

    return Scaffold(
      backgroundColor: BrandColors.offWhite,
      appBar: AppBar(
        leading: BackButton(onPressed: () => context.pop()),
        title: const Text('Mi evaluación'),
      ),
      body: driver == null
          ? const BrandLoader()
          : Builder(
              builder: (context) {
                final card = DriverScorecard.of(driver);
                return ListView(
                  padding: const EdgeInsets.all(Insets.lg),
                  children: [
                    _Summary(card: card),
                    if (card.reasons.isNotEmpty) ...[
                      const SizedBox(height: Insets.md),
                      InlineNotice(
                        key: const Key('evaluation-warning'),
                        tone: card.standing == DriverStanding.critical
                            ? NoticeTone.error
                            : NoticeTone.warning,
                        icon: Icons.info_outline,
                        message: 'La oficina está pendiente de: '
                            '${card.reasons.join('; ').toLowerCase()}.',
                      ),
                    ],
                    const SizedBox(height: Insets.lg),
                    FloatingCard(
                      child: Row(
                        children: [
                          _Figure(
                            key: const Key('evaluation-acceptance'),
                            value: card.acceptanceLabel,
                            label: 'Ofertas aceptadas',
                          ),
                          _Figure(
                            value: card.cancellationLabel,
                            label: 'Servicios cancelados',
                          ),
                          _Figure(
                            value: '${card.completed}',
                            label: 'Completados',
                          ),
                        ],
                      ),
                    ),
                    if (card.strengths.isNotEmpty) ...[
                      const SizedBox(height: Insets.lg),
                      _TagCard(
                        key: const Key('evaluation-strengths'),
                        title: 'Lo que más valoran',
                        tags: card.strengths,
                      ),
                    ],
                    if (card.complaints.isNotEmpty) ...[
                      const SizedBox(height: Insets.lg),
                      _TagCard(
                        key: const Key('evaluation-complaints'),
                        title: 'Qué mejorar',
                        tags: card.complaints,
                      ),
                    ],
                    if (driver.recentFeedback.isNotEmpty) ...[
                      const SizedBox(height: Insets.lg),
                      Text('Comentarios recientes', style: text.titleMedium),
                      const SizedBox(height: Insets.sm),
                      for (final feedback in driver.recentFeedback)
                        Padding(
                          padding: const EdgeInsets.only(bottom: Insets.sm),
                          child: _FeedbackCard(feedback: feedback),
                        ),
                    ],
                    const SizedBox(height: Insets.lg),
                    Text(
                      'Mantén tu promedio sobre '
                      '${DriverScorecard.watchAverage.toStringAsFixed(1)}, '
                      'acepta al menos el '
                      '${(DriverScorecard.watchAcceptance * 100).round()}% de '
                      'las ofertas y cancela menos del '
                      '${(DriverScorecard.watchCancelRate * 100).round()}% de '
                      'tus servicios.',
                      textAlign: TextAlign.center,
                      style: text.bodySmall
                          ?.copyWith(color: BrandColors.grey600),
                    ),
                  ],
                );
              },
            ),
    );
  }
}

class _Summary extends StatelessWidget {
  const _Summary({required this.card});

  final DriverScorecard card;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final max = card.starCounts.fold(0, (a, b) => a > b ? a : b);

    return FloatingCard(
      key: const Key('evaluation-summary'),
      child: Row(
        children: [
          Column(
            children: [
              Text(
                card.averageLabel,
                key: const Key('evaluation-average'),
                style: text.displaySmall,
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var star = 1; star <= 5; star++)
                    Icon(
                      star <= card.average.round()
                          ? Icons.star_rounded
                          : Icons.star_outline_rounded,
                      size: 18,
                      color: star <= card.average.round()
                          ? BrandColors.warning
                          : BrandColors.grey400,
                    ),
                ],
              ),
              const SizedBox(height: Insets.xxs),
              Text(
                card.hasRatings
                    ? '${card.ratingCount} '
                        '${card.ratingCount == 1 ? 'calificación' : 'calificaciones'}'
                    : 'Aún sin calificaciones',
                style: text.bodySmall?.copyWith(color: BrandColors.grey600),
              ),
              const SizedBox(height: Insets.xs),
              Text(
                card.standing.label,
                key: const Key('evaluation-standing'),
                style: text.labelLarge?.copyWith(
                  color: switch (card.standing) {
                    DriverStanding.critical => BrandColors.danger,
                    DriverStanding.watch => BrandColors.warning,
                    DriverStanding.excellent => BrandColors.success,
                    _ => BrandColors.grey800,
                  },
                ),
              ),
            ],
          ),
          const SizedBox(width: Insets.xl),
          Expanded(
            child: Column(
              children: [
                for (var star = 5; star >= 1; star--)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 16,
                          child: Text('$star', style: text.bodySmall),
                        ),
                        Expanded(
                          child: ClipRRect(
                            borderRadius: Corners.brXs,
                            child: LinearProgressIndicator(
                              value: max == 0
                                  ? 0
                                  : card.starCounts[star - 1] / max,
                              minHeight: 6,
                              color: BrandColors.warning,
                              backgroundColor: BrandColors.grey100,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Figure extends StatelessWidget {
  const _Figure({required this.value, required this.label, super.key});

  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Expanded(
      child: Column(
        children: [
          Text(value, style: text.titleLarge),
          Text(
            label,
            textAlign: TextAlign.center,
            style: text.bodySmall?.copyWith(color: BrandColors.grey600),
          ),
        ],
      ),
    );
  }
}

class _TagCard extends StatelessWidget {
  const _TagCard({required this.title, required this.tags, super.key});

  final String title;
  final List<(DriverRatingTag, int)> tags;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return FloatingCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: text.titleSmall),
          const SizedBox(height: Insets.sm),
          for (final (tag, count) in tags)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: Insets.xxs),
              child: Row(
                children: [
                  Icon(
                    tag.positive
                        ? Icons.thumb_up_alt_outlined
                        : Icons.flag_outlined,
                    size: 18,
                    color: tag.positive
                        ? BrandColors.success
                        : BrandColors.danger,
                  ),
                  const SizedBox(width: Insets.sm),
                  Expanded(child: Text(tag.label, style: text.bodyMedium)),
                  Text('$count', style: text.titleSmall),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _FeedbackCard extends StatelessWidget {
  const _FeedbackCard({required this.feedback});

  final DriverFeedback feedback;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return FloatingCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              for (var star = 1; star <= 5; star++)
                Icon(
                  star <= feedback.stars
                      ? Icons.star_rounded
                      : Icons.star_outline_rounded,
                  size: 16,
                  color: star <= feedback.stars
                      ? BrandColors.warning
                      : BrandColors.grey400,
                ),
            ],
          ),
          if (feedback.ratingTags.isNotEmpty) ...[
            const SizedBox(height: Insets.xxs),
            Text(
              feedback.ratingTags.map((t) => t.label).join(' · '),
              style: text.bodySmall?.copyWith(color: BrandColors.grey800),
            ),
          ],
          if (feedback.comment.isNotEmpty) ...[
            const SizedBox(height: Insets.xxs),
            Text('“${feedback.comment}”', style: text.bodyMedium),
          ],
        ],
      ),
    );
  }
}
