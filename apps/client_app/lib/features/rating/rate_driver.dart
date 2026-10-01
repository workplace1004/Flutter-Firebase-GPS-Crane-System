import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:grua_core/grua_core.dart';

/// The customer's latest finished tow still waiting for them to rate the
/// chofer, or null.
///
/// Looked up again whenever the active service changes, which is the moment a
/// tow ends: the router takes the customer off the tracking screen as soon as
/// it closes, so the rating has to find them on the home screen instead.
final FutureProvider<Service?> pendingDriverRatingProvider =
    FutureProvider.autoDispose<Service?>((ref) async {
  ref.watch(activeClientServiceProvider.select((a) => a.value?.id));
  final uid = ref.watch(currentUserIdProvider);
  if (uid == null) return null;
  final history = await ref
      .watch(serviceRepositoryProvider)
      .fetchHistory(userId: uid, role: UserRole.client, limit: 5);
  return switch (history) {
    Ok(:final value) =>
      latestUnrated(value.items, DateTime.now().toUtc(), canRateDriver),
    Err() => null,
  };
});

/// Opens the sheet to rate [service]'s chofer. True when a rating was sent.
Future<bool> showRateDriverSheet(
  BuildContext context,
  WidgetRef ref, {
  required Service service,
  int initialStars = 0,
}) async {
  final name = service.driverName.isEmpty ? 'tu chofer' : service.driverName;
  final sent = await showRatingSheet(
    context,
    key: const Key('rate-driver-sheet'),
    title: 'Califica a $name',
    tagsFor: DriverRatingTag.forStars,
    initialStars: initialStars,
    submit: (stars, tags, comment) =>
        ref.read(functionsGatewayProvider).rateService(
              serviceId: service.id,
              stars: stars,
              tags: tags,
              comment: comment,
            ),
  );
  if (sent) ref.invalidate(pendingDriverRatingProvider);
  return sent;
}

/// The rating on a finished service: an invitation while it can be given,
/// the customer's own rating once it has been, and nothing otherwise.
class RateDriverCard extends ConsumerWidget {
  const RateDriverCard({
    required this.service,
    this.onClose,
    this.compact = false,
    super.key,
  });

  final Service service;

  /// One short row, for the home screen.
  final bool compact;

  /// Puts the invitation off, where the card offers that.
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final given = service.ratings.clientToDriver;
    if (given != null && given.isRated) return _GivenRating(rating: given);
    if (!canRateDriver(service, DateTime.now().toUtc())) {
      return const SizedBox.shrink();
    }
    final name = service.driverName.isEmpty ? 'tu chofer' : service.driverName;
    return PendingRatingCard(
      key: const Key('rate-driver-card'),
      question: compact ? 'Califica a $name' : '¿Cómo te fue con $name?',
      subtitle: 'Tu calificación ayuda a mantener un buen servicio.',
      onClose: onClose,
      compact: compact,
      onStars: (stars) => unawaited(
        showRateDriverSheet(context, ref, service: service, initialStars: stars),
      ),
    );
  }
}

/// Asks for the rating the moment a tow ends — once per tow and session —
/// and keeps a card on the home screen until it is given or put off.
class PendingDriverRating extends ConsumerStatefulWidget {
  const PendingDriverRating({super.key});

  @override
  ConsumerState<PendingDriverRating> createState() =>
      _PendingDriverRatingState();
}

class _PendingDriverRatingState extends ConsumerState<PendingDriverRating> {
  void _promptFor(Service? service) {
    if (service == null) return;
    // Only a service that ended while the app was watching it pops up.
    if (!ref.read(finishedClientServicesProvider).contains(service.id)) return;
    if (ref.read(ratingPromptedProvider).contains(service.id)) return;
    ref.read(ratingPromptedProvider.notifier).add(service.id);
    // After this frame: a listener can fire mid-build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(showRateDriverSheet(context, ref, service: service));
    });
  }

  @override
  void initState() {
    super.initState();
    // A pending rating already known when the home screen opens.
    _promptFor(ref.read(pendingDriverRatingProvider).value);
  }

  @override
  Widget build(BuildContext context) {
    // Kept alive from here on, so a service ending is noticed.
    ref.watch(finishedClientServicesProvider);
    ref.listen(pendingDriverRatingProvider, (_, next) => _promptFor(next.value));

    final service = ref.watch(pendingDriverRatingProvider).value;
    final hidden = ref.watch(ratingDismissedProvider);
    if (service == null || hidden.contains(service.id)) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(Insets.gutter, 0, Insets.gutter, Insets.md),
      child: RateDriverCard(
        service: service,
        compact: true,
        onClose: () => ref.read(ratingDismissedProvider.notifier).add(service.id),
      ),
    );
  }
}

/// What the customer said, once said: it cannot be changed.
class _GivenRating extends StatelessWidget {
  const _GivenRating({required this.rating});

  final ServiceRating rating;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return FloatingCard(
      key: const Key('given-rating'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Tu calificación', style: text.titleMedium),
          const SizedBox(height: Insets.sm),
          Row(
            children: [
              for (var star = 1; star <= 5; star++)
                Icon(
                  star <= rating.stars
                      ? Icons.star_rounded
                      : Icons.star_outline_rounded,
                  size: 22,
                  color: star <= rating.stars
                      ? BrandColors.warning
                      : BrandColors.grey400,
                ),
            ],
          ),
          if (rating.ratingTags.isNotEmpty) ...[
            const SizedBox(height: Insets.sm),
            Wrap(
              spacing: Insets.xs,
              runSpacing: Insets.xs,
              children: [
                for (final tag in rating.ratingTags)
                  Chip(
                    label: Text(tag.label),
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
          ],
          if (rating.comment.isNotEmpty) ...[
            const SizedBox(height: Insets.sm),
            Text('“${rating.comment}”', style: text.bodyMedium),
          ],
        ],
      ),
    );
  }
}
