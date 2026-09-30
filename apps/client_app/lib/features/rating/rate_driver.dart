import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:grua_core/grua_core.dart';

/// How long after the tow the customer may rate it. `rateService` holds the
/// same line.
const ratingWindow = Duration(days: 7);

/// Whether the customer can still rate this service's chofer: their own
/// finished tow, not yet rated, within [ratingWindow].
///
/// An insurance company's tow is not rated from here: the insured has no
/// account in the app.
bool canRateDriver(Service service, DateTime now) {
  final finished = service.status == ServiceStatus.completed ||
      service.status == ServiceStatus.closed;
  if (!finished || !service.hasDriver || service.isInsurerJob) return false;
  if (service.ratings.clientToDriver?.isRated ?? false) return false;
  final at = service.timeline.completedAt;
  return at == null || now.difference(at) <= ratingWindow;
}

/// The rating on a finished service: an invitation while it can be given,
/// the customer's own rating once it has been, and nothing otherwise.
class RateDriverCard extends StatelessWidget {
  const RateDriverCard({required this.service, super.key});

  final Service service;

  @override
  Widget build(BuildContext context) {
    final given = service.ratings.clientToDriver;
    if (given != null && given.isRated) return _GivenRating(rating: given);
    if (!canRateDriver(service, DateTime.now().toUtc())) {
      return const SizedBox.shrink();
    }

    final text = Theme.of(context).textTheme;
    final name = service.driverName.isEmpty ? 'tu chofer' : service.driverName;
    return FloatingCard(
      key: const Key('rate-driver-card'),
      child: Column(
        children: [
          Text(
            '¿Cómo te fue con $name?',
            textAlign: TextAlign.center,
            style: text.titleMedium,
          ),
          const SizedBox(height: Insets.xs),
          Text(
            'Tu calificación ayuda a mantener un buen servicio.',
            textAlign: TextAlign.center,
            style: text.bodySmall?.copyWith(color: BrandColors.grey600),
          ),
          const SizedBox(height: Insets.md),
          _StarRow(
            stars: 0,
            size: 40,
            keyPrefix: 'rate-card-star',
            onSelected: (stars) => unawaited(
              showRateDriverSheet(context, service: service, initialStars: stars),
            ),
          ),
        ],
      ),
    );
  }
}

/// Opens the rating sheet. True when a rating was sent.
Future<bool> showRateDriverSheet(
  BuildContext context, {
  required Service service,
  int initialStars = 0,
}) async {
  final sent = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (_) => RateDriverSheet(service: service, initialStars: initialStars),
  );
  if ((sent ?? false) && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('¡Gracias por tu calificación!')),
    );
  }
  return sent ?? false;
}

class RateDriverSheet extends ConsumerStatefulWidget {
  const RateDriverSheet({
    required this.service,
    this.initialStars = 0,
    super.key,
  });

  final Service service;
  final int initialStars;

  @override
  ConsumerState<RateDriverSheet> createState() => _RateDriverSheetState();
}

class _RateDriverSheetState extends ConsumerState<RateDriverSheet> {
  late int _stars = widget.initialStars;
  final _tags = <DriverRatingTag>{};
  final _comment = TextEditingController();
  var _sending = false;
  String? _error;

  @override
  void dispose() {
    _comment.dispose();
    super.dispose();
  }

  void _setStars(int stars) => setState(() {
        // Praise and complaints do not travel together: changing sides clears
        // what was picked on the other one.
        if ((stars >= 4) != (_stars >= 4)) _tags.clear();
        _stars = stars;
        _error = null;
      });

  Future<void> _send() async {
    setState(() {
      _sending = true;
      _error = null;
    });
    final result = await ref.read(functionsGatewayProvider).rateService(
          serviceId: widget.service.id,
          stars: _stars,
          tags: _tags.toList(),
          comment: _comment.text.trim(),
        );
    if (!mounted) return;
    switch (result) {
      case Ok():
        Navigator.of(context).pop(true);
      case Err(:final failure):
        setState(() {
          _sending = false;
          _error = failure.userMessage;
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final name = widget.service.driverName.isEmpty
        ? 'tu chofer'
        : widget.service.driverName;

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: BottomActionSheet(
        child: SingleChildScrollView(
          child: Column(
            key: const Key('rate-driver-sheet'),
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Califica a $name',
                textAlign: TextAlign.center,
                style: text.titleMedium,
              ),
              const SizedBox(height: Insets.md),
              _StarRow(
                stars: _stars,
                size: 44,
                keyPrefix: 'rate-star',
                onSelected: _setStars,
              ),
              const SizedBox(height: Insets.xs),
              Text(
                _starsCaption(_stars),
                textAlign: TextAlign.center,
                style: text.bodySmall?.copyWith(color: BrandColors.grey600),
              ),
              if (_stars > 0) ...[
                const SizedBox(height: Insets.lg),
                FieldLabel(_stars >= 4 ? '¿Qué te gustó?' : '¿Qué salió mal?'),
                const SizedBox(height: Insets.sm),
                Wrap(
                  spacing: Insets.sm,
                  runSpacing: Insets.sm,
                  children: [
                    for (final tag in DriverRatingTag.forStars(_stars))
                      FilterChip(
                        key: Key('rate-tag-${tag.wire}'),
                        label: Text(tag.label),
                        selected: _tags.contains(tag),
                        onSelected: _sending
                            ? null
                            : (on) => setState(
                                  () => on ? _tags.add(tag) : _tags.remove(tag),
                                ),
                      ),
                  ],
                ),
                const SizedBox(height: Insets.lg),
                TextField(
                  key: const Key('rate-comment'),
                  controller: _comment,
                  enabled: !_sending,
                  maxLength: 500,
                  maxLines: 3,
                  minLines: 2,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: const InputDecoration(
                    hintText: 'Cuéntanos más (opcional)',
                  ),
                ),
              ],
              if (_error case final error?) ...[
                const SizedBox(height: Insets.sm),
                InlineNotice(message: error, tone: NoticeTone.error),
              ],
              const SizedBox(height: Insets.lg),
              ElevatedButton(
                key: const Key('rate-send'),
                onPressed: _stars == 0 || _sending ? null : _send,
                child: _sending
                    ? const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.4,
                          color: BrandColors.white,
                        ),
                      )
                    : const Text('ENVIAR CALIFICACIÓN'),
              ),
              TextButton(
                onPressed: _sending ? null : () => Navigator.of(context).pop(false),
                child: const Text('Ahora no'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _starsCaption(int stars) => switch (stars) {
      1 => 'Muy malo',
      2 => 'Malo',
      3 => 'Regular',
      4 => 'Bueno',
      5 => 'Excelente',
      _ => 'Toca una estrella',
    };

class _StarRow extends StatelessWidget {
  const _StarRow({
    required this.stars,
    required this.size,
    required this.keyPrefix,
    required this.onSelected,
  });

  final int stars;
  final double size;
  final String keyPrefix;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) => Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (var star = 1; star <= 5; star++)
            Semantics(
              button: true,
              selected: star <= stars,
              label: star == 1 ? '1 estrella' : '$star estrellas',
              child: IconButton(
                key: Key('$keyPrefix-$star'),
                iconSize: size,
                padding: EdgeInsets.zero,
                onPressed: () => onSelected(star),
                icon: Icon(
                  star <= stars ? Icons.star_rounded : Icons.star_outline_rounded,
                  color: star <= stars ? BrandColors.warning : BrandColors.grey400,
                ),
              ),
            ),
        ],
      );
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
