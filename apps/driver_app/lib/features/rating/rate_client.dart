import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:grua_core/grua_core.dart';

/// The chofer's latest finished job whose customer they have not rated yet,
/// or null. Looked up again whenever the job in hand changes — which is the
/// moment one ends.
final FutureProvider<Service?> pendingClientRatingProvider =
    FutureProvider.autoDispose<Service?>((ref) async {
  ref.watch(activeDriverServiceProvider.select((a) => a.value?.id));
  final uid = ref.watch(currentUserIdProvider);
  if (uid == null) return null;
  final history = await ref
      .watch(serviceRepositoryProvider)
      .fetchHistory(userId: uid, role: UserRole.driver, limit: 5);
  return switch (history) {
    Ok(:final value) =>
      latestUnrated(value.items, DateTime.now().toUtc(), canRateClient),
    Err() => null,
  };
});

/// Opens the sheet to rate [service]'s customer. True when a rating was sent.
Future<bool> showRateClientSheet(
  BuildContext context,
  WidgetRef ref, {
  required Service service,
  int initialStars = 0,
}) async {
  final name = service.clientName.isEmpty ? 'el cliente' : service.clientName;
  final sent = await showRatingSheet(
    context,
    key: const Key('rate-client-sheet'),
    title: 'Califica a $name',
    tagsFor: ClientRatingTag.forStars,
    initialStars: initialStars,
    submit: (stars, tags, comment) =>
        ref.read(functionsGatewayProvider).rateService(
              serviceId: service.id,
              stars: stars,
              tags: tags,
              comment: comment,
            ),
  );
  if (sent) ref.invalidate(pendingClientRatingProvider);
  return sent;
}

/// Asks the chofer to rate the customer the moment a job ends — once per job
/// and session — and keeps a card on the home screen until it is given or
/// put off. Only for customers with an account: an insurer's tow has nobody
/// to rate.
class PendingClientRating extends ConsumerStatefulWidget {
  const PendingClientRating({super.key});

  @override
  ConsumerState<PendingClientRating> createState() =>
      _PendingClientRatingState();
}

class _PendingClientRatingState extends ConsumerState<PendingClientRating> {
  void _promptFor(Service? service) {
    if (service == null) return;
    // Only a service that ended while the app was watching it pops up.
    if (!ref.read(finishedDriverServicesProvider).contains(service.id)) return;
    if (ref.read(ratingPromptedProvider).contains(service.id)) return;
    ref.read(ratingPromptedProvider.notifier).add(service.id);
    // After this frame: a listener can fire mid-build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(showRateClientSheet(context, ref, service: service));
    });
  }

  @override
  void initState() {
    super.initState();
    _promptFor(ref.read(pendingClientRatingProvider).value);
  }

  @override
  Widget build(BuildContext context) {
    // Kept alive from here on, so a service ending is noticed.
    ref.watch(finishedDriverServicesProvider);
    ref.listen(pendingClientRatingProvider, (_, next) => _promptFor(next.value));

    final service = ref.watch(pendingClientRatingProvider).value;
    final hidden = ref.watch(ratingDismissedProvider);
    if (service == null || hidden.contains(service.id)) {
      return const SizedBox.shrink();
    }
    final name = service.clientName.isEmpty ? 'el cliente' : service.clientName;
    return Padding(
      padding: const EdgeInsets.only(bottom: Insets.md),
      child: PendingRatingCard(
        key: const Key('rate-client-card'),
        question: 'Califica a $name',
        compact: true,
        onClose: () => ref.read(ratingDismissedProvider.notifier).add(service.id),
        onStars: (stars) => unawaited(
          showRateClientSheet(context, ref, service: service, initialStars: stars),
        ),
      ),
    );
  }
}
