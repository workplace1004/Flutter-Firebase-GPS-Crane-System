import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:grua_core/grua_core.dart';

import '../drivers/driver_details_dialog.dart';
import '../shared/page_parts.dart';
import '../shared/toast.dart';
import 'evaluation_widgets.dart';

/// How customers rate the choferes, and what the office does about it.
///
/// Two things to act on: the choferes whose record has slipped, and the
/// reviews flagged for a look — low stars, or a complaint of damage,
/// overcharging, rudeness or dangerous driving. A flagged review stays here
/// until someone writes down what they found.
class EvaluationsScreen extends ConsumerStatefulWidget {
  const EvaluationsScreen({super.key});

  @override
  ConsumerState<EvaluationsScreen> createState() => _EvaluationsScreenState();
}

enum _Filter { open, all }

class _EvaluationsScreenState extends ConsumerState<EvaluationsScreen> {
  _Filter _filter = _Filter.open;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final palette = context.palette;
    final open = ref.watch(openReviewsProvider);
    final reviews = _filter == _Filter.open ? open : ref.watch(recentReviewsProvider);
    final openCount = open.value?.length ?? 0;

    return ListView(
      padding: const EdgeInsets.all(Insets.xl),
      children: [
        Text('Evaluaciones', style: text.headlineSmall),
        const SizedBox(height: Insets.xs),
        Text(
          'Lo que dicen los clientes de cada chofer, y lo que hay que revisar.',
          style: text.bodyMedium?.copyWith(color: palette.textMuted),
        ),
        const SizedBox(height: Insets.xl),
        const _Attention(),
        const SizedBox(height: Insets.xl),
        Row(
          children: [
            Expanded(child: Text('Calificaciones', style: text.titleMedium)),
            SegmentedButton<_Filter>(
              segments: [
                ButtonSegment(
                  value: _Filter.open,
                  label: Text('Por revisar ($openCount)'),
                ),
                const ButtonSegment(value: _Filter.all, label: Text('Todas')),
              ],
              selected: {_filter},
              showSelectedIcon: false,
              onSelectionChanged: (s) => setState(() => _filter = s.first),
            ),
          ],
        ),
        const SizedBox(height: Insets.md),
        switch (reviews) {
          AsyncValue(:final error?) => InlineNotice(
              message: switch (error) {
                final Failure failure => failure.userMessage,
                _ => 'No se pudieron cargar las evaluaciones.',
              },
              tone: NoticeTone.error,
            ),
          AsyncValue(:final value?) when value.isEmpty => FloatingCard(
              child: EmptyState(
                icon: Icons.reviews_outlined,
                title: _filter == _Filter.open
                    ? 'Nada por revisar'
                    : 'Sin calificaciones todavía',
                message: _filter == _Filter.open
                    ? 'Las calificaciones bajas y las quejas graves aparecen '
                        'aquí para revisarlas.'
                    : 'Cuando los clientes califiquen a sus choferes, sus '
                        'opiniones aparecen aquí.',
              ),
            ),
          AsyncValue(:final value?) => ListCard(
              children: [
                for (final review in value)
                  _ReviewRow(key: ValueKey(review.serviceId), review: review),
              ],
            ),
          _ => const Padding(
              padding: EdgeInsets.all(Insets.xl),
              child: Center(child: CircularProgressIndicator()),
            ),
        },
      ],
    );
  }
}

/// The choferes whose record needs a word from the office, the worst first.
class _Attention extends ConsumerWidget {
  const _Attention();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    final palette = context.palette;
    final drivers = ref.watch(allDriversProvider).value ?? const [];

    final flagged = [
      for (final driver in drivers)
        if (!driver.archived)
          if (DriverScorecard.of(driver) case final card
              when card.standing.needsAttention)
            (driver: driver, card: card),
    ]..sort((a, b) => b.card.standing.index.compareTo(a.card.standing.index));

    if (flagged.isEmpty) {
      return FloatingCard(
        key: const Key('attention-none'),
        child: Row(
          children: [
            Icon(Icons.verified_outlined, color: palette.success),
            const SizedBox(width: Insets.md),
            Expanded(
              child: Text(
                'Ningún chofer en observación.',
                style: text.bodyMedium,
              ),
            ),
          ],
        ),
      );
    }

    return ListCard(
      key: const Key('attention-list'),
      title: 'Choferes en observación',
      trailing: Text(
        '${flagged.length}',
        style: text.titleMedium?.copyWith(color: palette.danger),
      ),
      children: [
        for (final (:driver, :card) in flagged)
          InkWell(
            key: ValueKey('attention-${driver.id}'),
            onTap: () => unawaited(showDriverDetailsDialog(context, driver)),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: Insets.lg,
                vertical: Insets.md,
              ),
              child: Row(
                children: [
                  DriverAvatar.of(driver),
                  const SizedBox(width: Insets.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(driver.name, style: text.titleSmall),
                        Text(
                          card.reasons.join(' · '),
                          style: text.bodySmall
                              ?.copyWith(color: palette.textMuted),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: Insets.md),
                  Text(
                    card.hasRatings ? '★ ${card.averageLabel}' : '—',
                    style: text.titleSmall,
                  ),
                  const SizedBox(width: Insets.md),
                  DriverStandingChip(standing: card.standing),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _ReviewRow extends ConsumerWidget {
  const _ReviewRow({required this.review, super.key});

  final DriverReview review;

  Future<void> _resolve(BuildContext context, WidgetRef ref) async {
    final note = await showDialog<String>(
      context: context,
      builder: (_) => _ResolveDialog(review: review),
    );
    if (note == null || !context.mounted) return;
    final result = await ref
        .read(functionsGatewayProvider)
        .resolveDriverReview(serviceId: review.serviceId, note: note);
    if (!context.mounted) return;
    switch (result) {
      case Ok():
        showToast(context, 'Evaluación revisada.', tone: ToastTone.success);
      case Err(:final failure):
        showToast(context, failure.userMessage, tone: ToastTone.error);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    final palette = context.palette;

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: Insets.lg,
        vertical: Insets.md,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ReviewSummary(review: review, showDriver: true),
                if (review.status == DriverReviewStatus.resolved) ...[
                  const SizedBox(height: Insets.xs),
                  Text(
                    'Revisada: ${review.resolutionNote}',
                    style: text.bodySmall?.copyWith(color: palette.success),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: Insets.md),
          if (review.isOpen)
            OutlinedButton(
              key: Key('resolve-${review.serviceId}'),
              onPressed: () => unawaited(_resolve(context, ref)),
              style: OutlinedButton.styleFrom(minimumSize: const Size(0, 36)),
              child: const Text('Marcar revisada'),
            ),
        ],
      ),
    );
  }
}

/// Asks what the office found. Returns the note, or null when cancelled.
class _ResolveDialog extends StatefulWidget {
  const _ResolveDialog({required this.review});

  final DriverReview review;

  @override
  State<_ResolveDialog> createState() => _ResolveDialogState();
}

class _ResolveDialogState extends State<_ResolveDialog> {
  final _note = TextEditingController();

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ready = _note.text.trim().length >= 3;
    return AlertDialog(
      title: const Text('Marcar como revisada'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ReviewSummary(review: widget.review, showDriver: true),
            const SizedBox(height: Insets.lg),
            TextField(
              key: const Key('resolve-note'),
              controller: _note,
              autofocus: true,
              maxLines: 3,
              maxLength: 1000,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                labelText: '¿Qué se hizo?',
                hintText: 'Ej.: Se llamó al cliente y se habló con el chofer.',
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
        ElevatedButton(
          key: const Key('resolve-confirm'),
          onPressed: ready
              ? () => Navigator.of(context).pop(_note.text.trim())
              : null,
          child: const Text('Guardar'),
        ),
      ],
    );
  }
}
