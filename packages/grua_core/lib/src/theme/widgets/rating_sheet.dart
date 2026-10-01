import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/enums.dart';
import '../../domain/failures.dart';
import '../../domain/models/service.dart';
import '../../providers.dart';
import '../brand.dart';
import 'brand_widgets.dart';

/// The services whose rating was offered once this session, so finishing a
/// tow asks once and reopening the home screen does not ask again.
final ratingPromptedProvider =
    NotifierProvider<RatingPromptSet, Set<String>>(RatingPromptSet.new);

/// The services whose "rate this" card was closed this session.
final ratingDismissedProvider =
    NotifierProvider<RatingPromptSet, Set<String>>(RatingPromptSet.new);

class RatingPromptSet extends Notifier<Set<String>> {
  @override
  Set<String> build() => const {};

  void add(String serviceId) => state = {...state, serviceId};
}

/// The services that ended while this session watched them — the customer's
/// tow, or the chofer's job — and so may ask for their rating at once.
///
/// A rating owed from before the app was opened waits on its card instead:
/// asking on every launch is nagging, asking as the tow ends is not.
final finishedClientServicesProvider =
    NotifierProvider<FinishedServices, Set<String>>(
  () => FinishedServices(activeClientServiceProvider),
);

/// As [finishedClientServicesProvider], for the chofer's jobs.
final finishedDriverServicesProvider =
    NotifierProvider<FinishedServices, Set<String>>(
  () => FinishedServices(activeDriverServiceProvider),
);

class FinishedServices extends Notifier<Set<String>> {
  FinishedServices(this._active);

  final StreamProvider<Service?> _active;

  @override
  Set<String> build() {
    ref.listen(_active, (previous, next) {
      final ended = previous?.value?.id;
      if (ended != null && next.value?.id != ended) {
        state = {...state, ended};
      }
    });
    return const {};
  }
}

/// Sends a rating. Returns the server's answer.
typedef RatingSubmit = Future<Result<void>> Function(
  int stars,
  List<RatingTag> tags,
  String comment,
);

/// Opens the rating sheet. True when a rating was sent, after thanking the
/// person for it.
Future<bool> showRatingSheet(
  BuildContext context, {
  required String title,
  required List<RatingTag> Function(int stars) tagsFor,
  required RatingSubmit submit,
  int initialStars = 0,
  Key? key,
}) async {
  final sent = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (_) => RatingSheet(
      key: key,
      title: title,
      tagsFor: tagsFor,
      submit: submit,
      initialStars: initialStars,
    ),
  );
  if ((sent ?? false) && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('¡Gracias por tu calificación!')),
    );
  }
  return sent ?? false;
}

/// Stars, then the tags that fit them — praise for four or five, complaints
/// for fewer — then an optional comment.
class RatingSheet extends StatefulWidget {
  const RatingSheet({
    required this.title,
    required this.tagsFor,
    required this.submit,
    this.initialStars = 0,
    super.key,
  });

  final String title;
  final List<RatingTag> Function(int stars) tagsFor;
  final RatingSubmit submit;
  final int initialStars;

  @override
  State<RatingSheet> createState() => _RatingSheetState();
}

class _RatingSheetState extends State<RatingSheet> {
  late int _stars = widget.initialStars;
  final _tags = <RatingTag>[];
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
    final result = await widget.submit(
      _stars,
      List.unmodifiable(_tags),
      _comment.text.trim(),
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

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: BottomActionSheet(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                widget.title,
                textAlign: TextAlign.center,
                style: text.titleMedium,
              ),
              const SizedBox(height: Insets.md),
              StarPicker(
                stars: _stars,
                size: 44,
                keyPrefix: 'rate-star',
                onSelected: _sending ? null : _setStars,
              ),
              const SizedBox(height: Insets.xs),
              Text(
                starsCaption(_stars),
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
                    for (final tag in widget.tagsFor(_stars))
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
                key: const Key('rate-later'),
                onPressed:
                    _sending ? null : () => Navigator.of(context).pop(false),
                child: const Text('Ahora no'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// "Muy malo" … "Excelente" under the stars.
String starsCaption(int stars) => switch (stars) {
      1 => 'Muy malo',
      2 => 'Malo',
      3 => 'Regular',
      4 => 'Bueno',
      5 => 'Excelente',
      _ => 'Toca una estrella',
    };

/// Five tappable stars.
class StarPicker extends StatelessWidget {
  const StarPicker({
    required this.stars,
    required this.onSelected,
    this.size = 40,
    this.keyPrefix = 'rate-star',
    super.key,
  });

  final int stars;
  final double size;

  /// Each star's key is `'$keyPrefix-$n'`, so a test can tap one.
  final String keyPrefix;
  final ValueChanged<int>? onSelected;

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
                // Small stars sit close together, still a thumb's width.
                constraints: size < 32
                    ? const BoxConstraints(minWidth: 36, minHeight: 36)
                    : null,
                onPressed: onSelected == null ? null : () => onSelected!(star),
                icon: Icon(
                  star <= stars ? Icons.star_rounded : Icons.star_outline_rounded,
                  color: star <= stars ? BrandColors.warning : BrandColors.grey400,
                ),
              ),
            ),
        ],
      );
}

/// A finished service waiting for its rating: a question and five stars, and
/// a way to put it off. Tapping a star opens the sheet on it.
class PendingRatingCard extends StatelessWidget {
  const PendingRatingCard({
    required this.question,
    required this.onStars,
    this.subtitle = '',
    this.onClose,
    this.compact = false,
    super.key,
  });

  final String question;
  final String subtitle;
  final ValueChanged<int> onStars;

  /// Hides the card for now. Null for a card that stays.
  final VoidCallback? onClose;

  /// One short row, for a home screen with little room to spare.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    if (compact) {
      return FloatingCard(
        padding: const EdgeInsets.fromLTRB(Insets.md, Insets.xs, 0, Insets.xs),
        child: Row(
          children: [
            Expanded(
              child: Text(
                question,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: text.titleSmall,
              ),
            ),
            StarPicker(
              stars: 0,
              size: 26,
              keyPrefix: 'rate-card-star',
              onSelected: onStars,
            ),
            if (onClose != null)
              IconButton(
                key: const Key('rate-card-close'),
                tooltip: 'Ahora no',
                visualDensity: VisualDensity.compact,
                onPressed: onClose,
                icon: const Icon(Icons.close, size: 18),
              ),
          ],
        ),
      );
    }
    return FloatingCard(
      child: Stack(
        children: [
          Column(
            children: [
              Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: onClose == null ? 0 : Insets.xl,
                ),
                child: Text(
                  question,
                  textAlign: TextAlign.center,
                  style: text.titleMedium,
                ),
              ),
              if (subtitle.isNotEmpty) ...[
                const SizedBox(height: Insets.xs),
                Text(
                  subtitle,
                  textAlign: TextAlign.center,
                  style: text.bodySmall?.copyWith(color: BrandColors.grey600),
                ),
              ],
              const SizedBox(height: Insets.sm),
              StarPicker(
                stars: 0,
                size: 36,
                keyPrefix: 'rate-card-star',
                onSelected: onStars,
              ),
            ],
          ),
          if (onClose != null)
            Positioned(
              top: -8,
              right: -8,
              child: IconButton(
                key: const Key('rate-card-close'),
                tooltip: 'Ahora no',
                onPressed: onClose,
                icon: const Icon(Icons.close, size: 18),
              ),
            ),
        ],
      ),
    );
  }
}
