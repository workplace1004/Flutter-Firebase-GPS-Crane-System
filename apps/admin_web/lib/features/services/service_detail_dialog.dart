import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:grua_core/grua_core.dart';

import '../../router.dart';
import '../shared/toast.dart';

/// Everything on file for one service, read-only.
///
/// Watches the service rather than showing the row it was opened from, so a
/// job still in progress keeps moving while the office reads it. [service] is
/// what is shown until the live copy arrives.
Future<void> showServiceDetailDialog(BuildContext context, Service service) =>
    showDialog<void>(
      context: context,
      builder: (context) => ServiceDetailDialog(service: service),
    );

class ServiceDetailDialog extends ConsumerWidget {
  const ServiceDetailDialog({required this.service, super.key});

  final Service service;

  /// Under this the two columns become one: a dispatcher on a 1024-px screen
  /// still gets the whole record, just stacked.
  static const _twoColumnsFrom = 780.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(serviceByIdProvider(service.id)).value ?? service;
    final events = ref.watch(serviceEventsProvider(s.id)).value ?? const [];
    final palette = context.palette;

    final quote = s.effectiveQuote;
    final timeline = s.timeline;
    final cancellation = s.cancellation;
    final rating = s.ratings.clientToDriver;

    // Who and what, then money and time. Reading down one column is a story;
    // reading across is not, which is why the split is by subject.
    final left = <Widget>[
      if (s.isInsurerJob)
        _Card(
          title: 'Aseguradora',
          icon: Icons.shield_outlined,
          rows: [
            ('Aseguradora', _orDash(s.insurerName)),
            ('Siniestro', _orDash(s.insurance?.claimNumber ?? '')),
            ('Póliza', _orDash(s.insurance?.policyNumber ?? '')),
            if (s.billing case final billing?)
              (
                'Zona',
                '${billing.zoneLabel} · ${billing.vehicleClass.label}',
              ),
          ],
        ),
      _Card(
        title: s.isInsurerJob ? 'Asegurado' : 'Cliente',
        icon: Icons.person_outline,
        rows: [
          ('Nombre', _orDash(s.clientName)),
          ('Teléfono', _orDash(s.clientPhone)),
        ],
        copyable: const {'Teléfono'},
      ),
      _Card(
        title: 'Vehículo',
        icon: Icons.directions_car_outlined,
        rows: [
          ('Vehículo', s.vehicle.displayName),
          ('Placa', _orDash(s.vehicle.plate)),
          ('Problema', s.vehicle.condition.label),
          if (s.vehicle.notes.isNotEmpty) ('Notas', s.vehicle.notes),
          ('Grúa requerida', s.truckTypeRequired.label),
        ],
      ),
      if (s.pickupPhotoPaths.isNotEmpty || s.dropoffPhotoPaths.isNotEmpty)
        _ProofPhotosCard(service: s),
      _Card(
        title: 'Chofer',
        icon: Icons.badge_outlined,
        rows: [
          if (s.hasDriver) ...[
            ('Nombre', _orDash(s.driverName)),
            ('Teléfono', _orDash(s.driverPhone)),
            (
              'Grúa',
              [s.truckPlate, s.truckLabel]
                  .where((p) => p.isNotEmpty)
                  .join(' · ')
                  .ifEmpty('—'),
            ),
            ('Asignación', s.assignmentMode.label),
          ] else
            ('Nombre', 'Sin asignar'),
        ],
        copyable: const {'Teléfono'},
      ),
      _Card(
        title: 'Recorrido',
        icon: Icons.route_outlined,
        rows: [
          ('Distancia', s.route.distanceLabel),
          ('Duración estimada', s.route.durationLabel),
        ],
      ),
    ];

    final right = <Widget>[
      _PriceCard(
        title: s.finalQuote == null ? 'Precio estimado' : 'Precio final',
        quote: quote,
      ),
      _Card(
        title: 'Pago',
        icon: Icons.payments_outlined,
        rows: [
          ('Método', s.payment.method.label),
          ('Estado', s.payment.status.label),
          if (s.payment.capturedCents > 0)
            ('Cobrado', s.payment.capturedCents.formatDOP),
          if (s.payment.failureMessage.isNotEmpty)
            ('Error', s.payment.failureMessage),
        ],
      ),
      _TimesCard(timeline: timeline, createdAt: s.createdAt),
      if (cancellation != null)
        _Card(
          title: 'Cancelación',
          icon: Icons.cancel_outlined,
          tone: palette.danger,
          rows: [
            ('Por', cancellation.by.label),
            ('Motivo', _orDash(cancellation.reason)),
            if (cancellation.hasFee)
              ('Cargo', cancellation.feeCents.formatDOP),
          ],
        ),
      if (rating != null && rating.isRated)
        _Card(
          title: 'Calificación al chofer',
          icon: Icons.star_outline,
          tone: palette.warning,
          rows: [
            ('Estrellas', '${rating.stars} de 5'),
            if (rating.ratingTags.isNotEmpty)
              ('Etiquetas', rating.ratingTags.map((t) => t.label).join(', ')),
            if (rating.comment.isNotEmpty) ('Comentario', rating.comment),
          ],
        ),
      if (s.ratings.driverToClient case final back? when back.isRated)
        _Card(
          key: const Key('driver-to-client-rating'),
          title: 'Calificación al cliente',
          icon: Icons.person_search_outlined,
          tone: palette.warning,
          rows: [
            ('Estrellas', '${back.stars} de 5'),
            if (back.tags.isNotEmpty)
              (
                'Etiquetas',
                [
                  for (final wire in back.tags)
                    if (ClientRatingTag.fromWire(wire) case final tag
                        when tag != ClientRatingTag.unknown)
                      tag.label,
                ].join(', '),
              ),
            if (back.comment.isNotEmpty) ('Comentario', back.comment),
          ],
        ),
      if (events.isNotEmpty) _History(events: events),
    ];

    return Dialog(
      backgroundColor: palette.surface,
      clipBehavior: Clip.antiAlias,
      shape: const RoundedRectangleBorder(borderRadius: Corners.brLg),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 940,
          maxHeight: MediaQuery.sizeOf(context).height * 0.9,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _Header(service: s),
            Divider(height: 1, color: palette.border),
            Flexible(
              child: ColoredBox(
                color: palette.canvas,
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(Insets.xl),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (s.status == ServiceStatus.needsManual) ...[
                        const InlineNotice(
                          message: 'La búsqueda automática no encontró chofer. '
                              'Asígnalo desde Operaciones.',
                          tone: NoticeTone.error,
                        ),
                        const SizedBox(height: Insets.lg),
                      ],
                      _SummaryStrip(service: s, quote: quote),
                      const SizedBox(height: Insets.lg),
                      _Panel(
                        child: RouteSummary(
                          pickup: s.pickup.displayAddress,
                          pickupReference: s.pickup.reference,
                          dropoff: s.dropoff?.displayAddress,
                        ),
                      ),
                      const SizedBox(height: Insets.lg),
                      LayoutBuilder(
                        builder: (context, constraints) {
                          if (constraints.maxWidth < _twoColumnsFrom) {
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: _spaced([...left, ...right]),
                            );
                          }
                          return Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: _spaced(left),
                                ),
                              ),
                              const SizedBox(width: Insets.lg),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: _spaced(right),
                                ),
                              ),
                            ],
                          );
                        },
                      ),
                    ],
                  ),
                ),
              ),
            ),
            _Footer(service: s),
          ],
        ),
      ),
    );
  }

  static List<Widget> _spaced(List<Widget> cards) => [
        for (var i = 0; i < cards.length; i++) ...[
          if (i > 0) const SizedBox(height: Insets.lg),
          cards[i],
        ],
      ];
}

String _orDash(String value) => value.trim().isEmpty ? '—' : value;

String _when(DateTime? at) => at == null ? '—' : DoTime.dateAndTime(at);

extension on String {
  String ifEmpty(String fallback) => isEmpty ? fallback : this;
}

/// The code, what state the job is in, and when it came in.
class _Header extends StatelessWidget {
  const _Header({required this.service});

  final Service service;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final palette = context.palette;
    final s = service;
    final code = s.code.isEmpty ? 'Servicio' : s.code;

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Insets.xl,
        Insets.lg,
        Insets.md,
        Insets.md,
      ),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: palette.brandTint,
              borderRadius: Corners.brSm,
            ),
            child: Icon(
              Icons.local_shipping_outlined,
              size: 20,
              color: palette.brand,
            ),
          ),
          const SizedBox(width: Insets.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: Insets.md,
                  runSpacing: Insets.xs,
                  children: [
                    Text(code, style: text.titleLarge),
                    StatusChip(s.status, label: s.status.officeLabel),
                    if (s.isInsurerJob)
                      Text(
                        s.insurerName,
                        style: text.bodySmall?.copyWith(
                          color: palette.textMuted,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: Insets.xxs),
                Text(
                  'Solicitado ${_when(s.createdAt ?? s.timeline.createdAt)}',
                  style: text.bodySmall?.copyWith(color: palette.textMuted),
                ),
              ],
            ),
          ),
          // The code is what the office pastes into WhatsApp or a chofer call.
          if (s.code.isNotEmpty)
            IconButton(
              key: const Key('copy-service-code'),
              onPressed: () => _copy(context, s.code, 'Código copiado'),
              icon: const Icon(Icons.copy_outlined, size: 18),
              tooltip: 'Copiar el código',
            ),
          IconButton(
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.close, size: 20),
            tooltip: 'Cerrar',
          ),
        ],
      ),
    );
  }
}

void _copy(BuildContext context, String value, String said) {
  unawaited(Clipboard.setData(ClipboardData(text: value)));
  showToast(context, said);
}

/// The four figures somebody opens this dialog for, before reading anything.
class _SummaryStrip extends StatelessWidget {
  const _SummaryStrip({required this.service, required this.quote});

  final Service service;
  final Quote quote;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final s = service;

    return Wrap(
      spacing: Insets.md,
      runSpacing: Insets.md,
      children: [
        _Stat(
          label: s.finalQuote == null ? 'Total estimado' : 'Total',
          value: quote.totalCents.formatDOPShort,
          icon: Icons.attach_money,
          tone: palette.brand,
        ),
        _Stat(
          label: 'Forma de pago',
          value: s.payment.method.label,
          detail: s.payment.status.label,
          icon: Icons.account_balance_wallet_outlined,
        ),
        _Stat(
          label: 'Distancia y tiempo',
          value: s.route.distanceLabel,
          detail: s.route.durationLabel,
          icon: Icons.straighten,
        ),
        _Stat(
          label: 'Chofer asignado',
          value: s.hasDriver ? _orDash(s.driverName) : 'Sin asignar',
          detail: s.hasDriver ? _orDash(s.truckPlate) : null,
          icon: Icons.person_pin_circle_outlined,
          tone: s.hasDriver ? null : palette.warning,
        ),
      ],
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({
    required this.label,
    required this.value,
    required this.icon,
    this.detail,
    this.tone,
  });

  final String label;
  final String value;
  final String? detail;
  final IconData icon;
  final Color? tone;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final palette = context.palette;

    return Container(
      width: 208,
      // One height for all four, so they read as a band rather than as cards
      // of different sizes; a minimum rather than a fixed box, so a larger
      // text setting grows the tile instead of clipping it.
      constraints: const BoxConstraints(minHeight: 80),
      padding: const EdgeInsets.all(Insets.md),
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: Corners.brSm,
        border: Border.all(color: palette.border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: tone ?? palette.textFaint),
          const SizedBox(width: Insets.sm),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label.toUpperCase(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.labelSmall?.copyWith(color: palette.textMuted),
                ),
                const SizedBox(height: Insets.xxs),
                Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.titleSmall?.copyWith(color: tone ?? palette.text),
                ),
                if (detail != null)
                  Text(
                    detail!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.bodySmall?.copyWith(color: palette.textMuted),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The white block every group of the record sits in.
class _Panel extends StatelessWidget {
  const _Panel({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;

    return Container(
      padding: const EdgeInsets.all(Insets.lg),
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: Corners.brMd,
        border: Border.all(color: palette.border),
      ),
      child: child,
    );
  }
}

/// A titled group of label / value rows.
class _Card extends StatelessWidget {
  const _Card({
    required this.title,
    required this.icon,
    required this.rows,
    this.tone,
    this.copyable = const {},
    super.key,
  });

  final String title;
  final IconData icon;
  final List<(String, String)> rows;

  /// Colours the icon and title where the group itself is the news — a
  /// cancellation, a rating.
  final Color? tone;

  /// Labels whose value gets a copy button: a phone number is dialled from
  /// another program, never read out of the screen.
  final Set<String> copyable;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final palette = context.palette;

    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _CardTitle(title: title, icon: icon, tone: tone),
          const SizedBox(height: Insets.md),
          for (final (label, value) in rows)
            Padding(
              padding: const EdgeInsets.only(bottom: Insets.sm),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 132,
                    child: Text(
                      label,
                      style: text.bodySmall?.copyWith(color: palette.textMuted),
                    ),
                  ),
                  Expanded(child: Text(value, style: text.bodyMedium)),
                  if (copyable.contains(label) && value != '—')
                    InkWell(
                      onTap: () => _copy(context, value, '$label copiado'),
                      borderRadius: Corners.brXs,
                      child: Padding(
                        padding: const EdgeInsets.all(Insets.xxs),
                        child: Icon(
                          Icons.copy_outlined,
                          size: 14,
                          color: palette.textFaint,
                        ),
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

/// The chofer's photos of the vehicle as it was loaded and as it was handed
/// over: what the office opens when a customer says the grúa made the dent.
class _ProofPhotosCard extends StatelessWidget {
  const _ProofPhotosCard({required this.service});

  final Service service;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final palette = context.palette;

    return _Panel(
      child: Column(
        key: const Key('proof-photos'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _CardTitle(
            title: 'Fotos del chofer',
            icon: Icons.photo_camera_outlined,
          ),
          for (final (stage, paths) in [
            (ServicePhotoStage.pickup, service.pickupPhotoPaths),
            (ServicePhotoStage.dropoff, service.dropoffPhotoPaths),
          ])
            if (paths.isNotEmpty) ...[
              const SizedBox(height: Insets.md),
              Text(
                stage.label,
                style: text.bodySmall?.copyWith(color: palette.textMuted),
              ),
              const SizedBox(height: Insets.xs),
              _ProofPhotoStrip(key: Key('proof-${stage.wire}'), paths: paths),
            ],
        ],
      ),
    );
  }
}

/// Resolves each stored path to a URL and draws the ones that resolved.
class _ProofPhotoStrip extends ConsumerWidget {
  const _ProofPhotoStrip({required this.paths, super.key});

  final List<String> paths;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final urls = [
      for (final path in paths) ?ref.watch(servicePhotoUrlProvider(path)).value,
    ];
    if (urls.isEmpty) {
      return Text(
        'Cargando ${paths.length} ${paths.length == 1 ? 'foto' : 'fotos'}…',
        style: Theme.of(context).textTheme.bodySmall,
      );
    }
    return VehiclePhotoStrip(urls: urls, size: 72);
  }
}

class _CardTitle extends StatelessWidget {
  const _CardTitle({required this.title, required this.icon, this.tone});

  final String title;
  final IconData icon;
  final Color? tone;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;

    return Row(
      children: [
        Icon(icon, size: 16, color: tone ?? palette.textFaint),
        const SizedBox(width: Insets.sm),
        // Wraps rather than running past a narrow column.
        Flexible(child: FieldLabel(title.toUpperCase())),
      ],
    );
  }
}

/// What the job costs, with the total carrying the weight: it is the one
/// figure the office reads out loud.
class _PriceCard extends StatelessWidget {
  const _PriceCard({required this.title, required this.quote});

  final String title;
  final Quote quote;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final palette = context.palette;

    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _CardTitle(title: title, icon: Icons.request_quote_outlined),
          const SizedBox(height: Insets.md),
          for (final line in quote.breakdown)
            Padding(
              padding: const EdgeInsets.only(bottom: Insets.sm),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      line.label,
                      style: text.bodySmall?.copyWith(
                        color: palette.textMuted,
                      ),
                    ),
                  ),
                  const SizedBox(width: Insets.md),
                  Text(line.cents.formatDOP, style: text.bodyMedium),
                ],
              ),
            ),
          Divider(color: palette.borderSubtle, height: Insets.lg),
          Row(
            children: [
              Expanded(child: Text('Total', style: text.titleSmall)),
              Text(
                quote.totalCents.formatDOP,
                style: text.titleMedium?.copyWith(color: palette.text),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The job as a line of moments, and under it what each step took.
class _TimesCard extends StatelessWidget {
  const _TimesCard({required this.timeline, required this.createdAt});

  final ServiceTimeline timeline;
  final DateTime? createdAt;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final palette = context.palette;
    final t = timeline;

    final steps = <(String, DateTime?)>[
      ('Solicitado', t.createdAt ?? createdAt),
      if (t.acceptedAt != null) ('Aceptado', t.acceptedAt),
      if (t.arrivedAt != null) ('Llegó al punto', t.arrivedAt),
      if (t.startedAt != null) ('Inició el remolque', t.startedAt),
      if (t.completedAt != null) ('Completado', t.completedAt),
      if (t.closedAt != null) ('Cerrado', t.closedAt),
      if (t.cancelledAt != null) ('Cancelado', t.cancelledAt),
    ];
    final spans = <(String, Duration)>[
      if (t.timeToAccept case final d?) ('Espera por chofer', d),
      if (t.timeToArrive case final d?) ('Tiempo de llegada', d),
      if (t.serviceDuration case final d?) ('Duración del remolque', d),
    ];

    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _CardTitle(title: 'Tiempos', icon: Icons.schedule_outlined),
          const SizedBox(height: Insets.md),
          for (var i = 0; i < steps.length; i++)
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _Rail(first: i == 0, last: i == steps.length - 1),
                  const SizedBox(width: Insets.md),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: Insets.md),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Text(steps[i].$1, style: text.bodyMedium),
                          ),
                          const SizedBox(width: Insets.sm),
                          Text(
                            _when(steps[i].$2),
                            style: text.bodySmall?.copyWith(
                              color: palette.textMuted,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          if (spans.isNotEmpty) ...[
            Divider(color: palette.borderSubtle, height: Insets.md),
            const SizedBox(height: Insets.sm),
            Wrap(
              spacing: Insets.sm,
              runSpacing: Insets.sm,
              children: [
                for (final (label, span) in spans)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: Insets.sm,
                      vertical: Insets.xs,
                    ),
                    decoration: BoxDecoration(
                      color: palette.surfaceSubtle,
                      borderRadius: Corners.brXs,
                    ),
                    child: Text(
                      '$label · ${DoTime.duration(span)}',
                      style: text.bodySmall?.copyWith(
                        color: palette.textStrong,
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// The dot and the thread between two moments.
class _Rail extends StatelessWidget {
  const _Rail({required this.first, required this.last});

  final bool first;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;

    return SizedBox(
      width: 10,
      child: Column(
        children: [
          SizedBox(
            height: 8,
            child: first
                ? null
                : Center(
                    child: Container(width: 1.5, color: palette.border),
                  ),
          ),
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: first ? palette.brand : palette.border,
              shape: BoxShape.circle,
            ),
          ),
          if (!last)
            Expanded(
              child: Center(
                child: Container(width: 1.5, color: palette.border),
              ),
            ),
        ],
      ),
    );
  }
}

/// The transition log, oldest first: who moved the job, and when.
class _History extends StatelessWidget {
  const _History({required this.events});

  final List<ServiceEvent> events;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final palette = context.palette;

    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _CardTitle(title: 'Historial', icon: Icons.history),
          const SizedBox(height: Insets.md),
          for (final event in events)
            Padding(
              padding: const EdgeInsets.only(bottom: Insets.sm),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Icon(Icons.circle, size: 7, color: palette.brand),
                  ),
                  const SizedBox(width: Insets.sm),
                  Expanded(
                    child: Text(event.description, style: text.bodyMedium),
                  ),
                  if (event.at != null)
                    Text(
                      DoTime.dateAndTime(event.at!),
                      style: text.bodySmall?.copyWith(
                        color: palette.textMuted,
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

class _Footer extends StatelessWidget {
  const _Footer({required this.service});

  final Service service;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;

    return Container(
      padding: const EdgeInsets.all(Insets.md),
      decoration: BoxDecoration(
        color: palette.surface,
        border: Border(top: BorderSide(color: palette.border)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          // Where a live job is acted on: the map, the chofer's position and
          // the manual assignment all live there.
          if (service.isActive) ...[
            OutlinedButton.icon(
              onPressed: () {
                Navigator.of(context).pop();
                context.go(Routes.operationsFor(service.id));
              },
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(0, 40),
                padding: const EdgeInsets.symmetric(horizontal: Insets.lg),
              ),
              icon: const Icon(Icons.map_outlined, size: 18),
              label: const Text('Ver en Operaciones'),
            ),
            const SizedBox(width: Insets.sm),
          ],
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(),
            style: ElevatedButton.styleFrom(
              minimumSize: const Size(0, 40),
              padding: const EdgeInsets.symmetric(horizontal: Insets.lg),
            ),
            child: const Text('Cerrar'),
          ),
        ],
      ),
    );
  }
}
