import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:grua_core/grua_core.dart';

import '../../router.dart';
import '../payment/payment_choice_card.dart';
import '../rating/rate_driver.dart';

/// What the customer watches while they wait on the shoulder.
///
/// Red ground, the status as the headline, the map in a card with the truck
/// gliding across it, and three actions at the bottom. The status line is
/// deliberately vague about dispatch: a customer watching `offered` flick back
/// to `pending_dispatch` five times as the cascade works loses confidence in a
/// system that is behaving correctly.
class TrackingScreen extends ConsumerWidget {
  const TrackingScreen({required this.serviceId, super.key});

  final String serviceId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final serviceAsync = ref.watch(serviceByIdProvider(serviceId));
    // Started here, while the tow is on, so its end is noticed and the
    // rating asked for on the home screen the router sends the customer to.
    ref.watch(finishedClientServicesProvider);

    return Scaffold(
      backgroundColor: BrandColors.red,
      body: serviceAsync.when(
        loading: () => const Center(
          child: CircularProgressIndicator(color: BrandColors.white),
        ),
        error: (error, _) => _ErrorBody(
          message: 'No pudimos cargar tu servicio.',
          onBack: () => context.go(Routes.home),
        ),
        data: (service) {
          if (service == null) {
            return _ErrorBody(
              message: 'Este servicio ya no existe.',
              onBack: () => context.go(Routes.home),
            );
          }
          return _TrackingBody(service: service);
        },
      ),
    );
  }
}

class _TrackingBody extends ConsumerWidget {
  const _TrackingBody({required this.service});

  final Service service;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tracking = ref.watch(serviceTrackingProvider(service.id)).value;
    final text = Theme.of(context).textTheme;
    final now = DateTime.now().toUtc();

    if (service.isTerminal) {
      return _TerminalBody(service: service);
    }

    return SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Insets.gutter),
            child: Row(
              children: [
                const GruaLogo(size: 78),
                const Spacer(),
                Text(
                  service.code,
                  style: text.labelMedium?.copyWith(color: Colors.white70),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: Insets.gutter,
              vertical: Insets.md,
            ),
            child: Text(
              service.awaitsOperator
                  ? 'Esperando confirmación'
                  : service.status.label,
              textAlign: TextAlign.center,
              style: text.headlineLarge?.copyWith(color: BrandColors.white),
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: Insets.gutter),
              child: _MapCard(
                service: service,
                tracking: tracking,
                now: now,
                hasApiKey: ref.watch(hasMapsKeyProvider),
              ),
            ),
          ),
          const SizedBox(height: Insets.lg),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Insets.gutter),
            child: _DriverCard(service: service, tracking: tracking, now: now),
          ),
          // The grúa is at the curb: what the tow costs is on screen before
          // the vehicle is loaded, not at the destination.
          if (service.status == ServiceStatus.arrived) ...[
            const SizedBox(height: Insets.md),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Insets.gutter),
              child: PaymentChoiceCard(service: service),
            ),
          ],
          const SizedBox(height: Insets.lg),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              Insets.gutter,
              0,
              Insets.gutter,
              Insets.lg,
            ),
            child: _Actions(service: service),
          ),
        ],
      ),
    );
  }
}

class _MapCard extends ConsumerStatefulWidget {
  const _MapCard({
    required this.service,
    required this.tracking,
    required this.now,
    required this.hasApiKey,
  });

  final Service service;
  final ServiceTracking? tracking;
  final DateTime now;
  final bool hasApiKey;

  @override
  ConsumerState<_MapCard> createState() => _MapCardState();
}

class _MapCardState extends ConsumerState<_MapCard> {
  /// While true the camera rides with the truck. The customer's own touch
  /// turns it off — and only their touch, so a position update never steals
  /// the map back mid-pinch.
  ///
  /// The map used to be `interactive: false` for exactly this reason: the
  /// truck moves every few seconds, and a camera that follows it fights any
  /// pan. Locking the map was the wrong half of that trade — somebody on the
  /// shoulder wants to see which side of the river the grúa is on, and zoom in
  /// on the street it is turning into.
  var _following = true;

  /// Where the camera was handed over. Held constant so [GruaMap] sees no
  /// change of `center` and leaves the customer's camera alone.
  LatLng? _held;

  void _takeOver(LatLng from) {
    if (!_following) return;
    setState(() {
      _following = false;
      _held = from;
    });
  }

  void _follow() => setState(() {
        _following = true;
        _held = null;
      });

  @override
  Widget build(BuildContext context) {
    final service = widget.service;
    final tracking = widget.tracking;
    final truckAt = tracking?.position;
    final stale = tracking?.isStale(widget.now) ?? true;
    final followed = truckAt ?? service.pickup.geo;

    // The roads the grúa will actually drive. Both legs are fetched the way
    // the chofer's own map fetches them, and each falls back to a straight
    // line on its own if there is no answer — so there is always a line, and
    // it is the real one whenever it can be.
    final dropoff = service.dropoff?.geo;
    // The server routed this tow once, at quote time, and every screen draws
    // that same path. Fetching our own is the fallback for a service quoted
    // before it did — or one quoted while the Routes API was unreachable.
    final stored = service.towPath;
    final tow = stored.isNotEmpty
        ? stored
        : dropoff == null
            ? null
            : ref.watch(roadRouteProvider((service.pickup.geo, dropoff))).value
                ?.points;
    final toPickup = truckAt == null
        ? null
        : ref
            .watch(roadRouteProvider((routeGrain(truckAt), service.pickup.geo)))
            .value;

    return ClipRRect(
      borderRadius: Corners.brLg,
      child: Stack(
        children: [
          Positioned.fill(
            // Not a `Listener` around the map: on the web the map is a
            // platform view and the browser takes the pointer events before
            // Flutter sees them. The map itself reports the move, and says
            // whether it was ours.
            child: GruaMap(
              center: _following ? followed : (_held ?? followed),
              hasApiKey: widget.hasApiKey,
              zoom: 14.2,
              showAttribution: false,
              expandable: true,
              onUserMove: () => _takeOver(followed),
              // Red is the leg the truck is driving now; the tow ahead of it
              // sits behind in dark dashes, the way the chofer's map draws the
              // same two.
              // Nothing until there is a truck. The fallback used to be the
              // pickup and the destination, which drew a straight red copy of
              // the tow right over the real one while the customer was still
              // waiting for a chofer.
              route: truckAt == null
                  ? const []
                  : toPickup?.points ?? [truckAt, service.pickup.geo],
              routes: [
                if (tow != null)
                  MapRoute(points: tow, color: BrandColors.ink, dashed: true)
                // Only while the road is still being fetched.
                else if (dropoff != null)
                  MapRoute(
                    points: [service.pickup.geo, dropoff],
                    color: BrandColors.ink,
                    dashed: true,
                  ),
              ],
              markers: [
                MapMarker(
                  position: service.pickup.geo,
                  kind: MapMarkerKind.pickup,
                ),
                if (service.dropoff != null)
                  MapMarker(
                    position: service.dropoff!.geo,
                    kind: MapMarkerKind.dropoff,
                  ),
                if (truckAt != null)
                  MapMarker(
                    position: truckAt,
                    kind: stale
                        ? MapMarkerKind.truckStale
                        : MapMarkerKind.truckOnService,
                    heading: tracking?.heading ?? 0,
                  ),
              ],
            ),
          ),
          if (tracking != null)
            Positioned(
              top: Insets.lg,
              left: 0,
              right: 0,
              child: Center(child: _EtaBubble(tracking: tracking, stale: stale)),
            ),
          // Only once they have taken the camera: a button that does nothing
          // is noise over a map.
          if (!_following)
            Positioned(
              // Bottom left, above Google's logo: the bottom-right corner is
              // where the map draws its own controls on the web.
              left: Insets.md,
              bottom: Insets.huge,
              child: Tooltip(
                message: 'Seguir la grúa',
                child: FloatingCard(
                  key: const Key('follow-truck'),
                  padding: const EdgeInsets.all(Insets.md),
                  borderRadius: Corners.brMd,
                  onTap: _follow,
                  child: const Icon(
                    Icons.my_location,
                    color: BrandColors.red,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The "ETA 12 mins" callout from the mockup.
class _EtaBubble extends StatelessWidget {
  const _EtaBubble({required this.tracking, required this.stale});

  final ServiceTracking tracking;
  final bool stale;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;

    return FloatingCard(
      padding: const EdgeInsets.symmetric(
        horizontal: Insets.lg,
        vertical: Insets.md,
      ),
      borderRadius: Corners.brMd,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            stale ? Icons.wifi_off : Icons.local_shipping,
            size: 20,
            color: stale ? BrandColors.grey600 : BrandColors.red,
          ),
          const SizedBox(width: Insets.sm),
          Text(
            // A frozen marker in the wrong place is worse than admitting the
            // connection dropped.
            stale ? 'Reconectando con el chofer…' : 'Llega en ${tracking.etaLabel}',
            style: text.titleMedium,
          ),
        ],
      ),
    );
  }
}

class _DriverCard extends StatelessWidget {
  const _DriverCard({
    required this.service,
    required this.tracking,
    required this.now,
  });

  final Service service;
  final ServiceTracking? tracking;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;

    if (service.awaitsOperator) return _OperatorReviewCard(service: service);

    if (!service.hasDriver) {
      final confirmed = service.operatorReview?.isConfirmed ?? false;
      return FloatingCard(
        child: Row(
          children: [
            const SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2.4),
            ),
            const SizedBox(width: Insets.lg),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Buscando la grúa más cercana', style: text.titleSmall),
                  const SizedBox(height: 2),
                  Text(
                    confirmed
                        ? 'Precio confirmado: ${service.totalCents.formatDOPShort}. '
                            'Te avisamos apenas un chofer acepte.'
                        : 'Te avisamos apenas un chofer acepte.',
                    style: text.bodySmall?.copyWith(color: BrandColors.grey600),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    final remaining = tracking?.remainingMeters ?? 0;
    final distanceLabel = remaining >= 1000
        ? '${(remaining / 1000).toStringAsFixed(1)} km'
        : '$remaining m';

    return FloatingCard(
      child: Column(
        children: [
          Row(
            children: [
              // The chofer's photo, so the customer knows the face of who
              // is getting out of the truck. It used to be only the first
              // letter of their name, whatever photo the chofer had.
              DriverAvatar(
                key: const Key('driver-photo'),
                name: service.driverName,
                photoUrl: service.driverPhotoUrl,
                size: 48,
              ),
              const SizedBox(width: Insets.lg),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(service.driverName, style: text.titleMedium),
                    const SizedBox(height: 2),
                    Text(
                      [
                        if (service.truckPlate.isNotEmpty) service.truckPlate,
                        if (service.truckLabel.isNotEmpty) service.truckLabel,
                      ].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.bodySmall?.copyWith(color: BrandColors.grey600),
                    ),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.star, size: 15, color: BrandColors.warning),
                      const SizedBox(width: 2),
                      Text(
                        // A chofer nobody has rated yet is new, not 0.0.
                        service.driverRating > 0
                            ? service.driverRating.toStringAsFixed(1)
                            : 'Nuevo',
                        style: text.labelMedium,
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    distanceLabel,
                    style: text.bodySmall?.copyWith(color: BrandColors.grey600),
                  ),
                ],
              ),
            ],
          ),
          const Divider(height: Insets.xxl),
          RouteSummary(
            pickup: service.pickup.displayAddress,
            pickupReference: service.pickup.reference,
            dropoff: service.dropoff?.displayAddress,
          ),
          const SizedBox(height: Insets.md),
          Row(
            children: [
              Expanded(
                child: Text(
                  service.payment.isPaid
                      ? service.payment.status.label
                      : 'Pagas en efectivo al terminar',
                  style: text.bodyMedium?.copyWith(color: BrandColors.grey600),
                ),
              ),
              Text(service.totalCents.formatDOP, style: text.titleMedium),
            ],
          ),
        ],
      ),
    );
  }
}

/// A heavy request, waiting for the operator to confirm a grúa and the price.
///
/// Said plainly, with the estimate: nobody is on the way yet, and the price
/// the customer saw can still change.
class _OperatorReviewCard extends StatelessWidget {
  const _OperatorReviewCard({required this.service});

  final Service service;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return FloatingCard(
      key: const Key('operator-review-card'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.support_agent, color: BrandColors.red),
              const SizedBox(width: Insets.md),
              Expanded(
                child: Text(
                  'Esperando confirmación del operador',
                  style: text.titleSmall,
                ),
              ),
            ],
          ),
          const SizedBox(height: Insets.sm),
          Text(
            heavyServiceNotice,
            style: text.bodySmall?.copyWith(color: BrandColors.grey600),
          ),
          const SizedBox(height: Insets.md),
          Row(
            children: [
              Expanded(
                child: Text(
                  'Precio estimado',
                  style: text.bodyMedium?.copyWith(color: BrandColors.grey600),
                ),
              ),
              Text(service.totalCents.formatDOPShort, style: text.titleMedium),
            ],
          ),
        ],
      ),
    );
  }
}

class _Actions extends ConsumerStatefulWidget {
  const _Actions({required this.service});

  final Service service;

  @override
  ConsumerState<_Actions> createState() => _ActionsState();
}

class _ActionsState extends ConsumerState<_Actions> {
  /// True from "Sí, cancelar" until the server answers, so the button shows it
  /// is working and a second tap cannot send a second cancellation.
  var _cancelling = false;

  Service get service => widget.service;

  Future<void> _cancel() async {
    if (_cancelling) return;
    final now = DateTime.now().toUtc();
    final fee = service.cancellationIncursFee(now);

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('¿Cancelar el servicio?'),
        content: Text(
          fee
              ? 'El chofer ya va en camino, así que se aplicará un cargo por '
                  'cancelación.'
              : 'Todavía no se aplica ningún cargo.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Volver'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(foregroundColor: BrandColors.danger),
            child: const Text('Sí, cancelar'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    setState(() => _cancelling = true);
    final result = await ref.read(functionsGatewayProvider).cancelService(
          serviceId: service.id,
          reason: 'client_request',
        );
    if (!mounted) return;
    setState(() => _cancelling = false);

    result.fold(
      (_) => context.go(Routes.home),
      (failure) => ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(failure.userMessage)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final canContact = service.canChat;

    return Row(
      children: [
        Expanded(
          child: _ActionButton(
            icon: Icons.chat_bubble_outline,
            label: 'Chat',
            onTap: canContact
                ? () => context.push(Routes.chatFor(service.id))
                : null,
          ),
        ),
        const SizedBox(width: Insets.md),
        Expanded(
          child: _ActionButton(
            icon: Icons.call_outlined,
            label: 'Llamar',
            // An in-app voice call to the chofer's app.
            onTap: canContact
                ? () => unawaited(
                      ref.read(callControllerProvider.notifier).call(
                            serviceId: service.id,
                            peerName: service.driverName,
                          ),
                    )
                : null,
          ),
        ),
        const SizedBox(width: Insets.md),
        Expanded(
          child: _ActionButton(
            icon: Icons.videocam_outlined,
            label: 'Video',
            // An in-app video call to the chofer's app.
            onTap: canContact
                ? () => unawaited(
                      ref.read(callControllerProvider.notifier).call(
                            serviceId: service.id,
                            peerName: service.driverName,
                            video: true,
                          ),
                    )
                : null,
          ),
        ),
        const SizedBox(width: Insets.md),
        Expanded(
          child: _ActionButton(
            icon: Icons.close,
            label: 'Cancelar',
            destructive: true,
            loading: _cancelling,
            onTap: service.isCancellableByClient ? _cancel : null,
          ),
        ),
      ],
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.destructive = false,
    this.loading = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool destructive;

  /// Swaps the icon for a spinner and ignores taps, keeping the button's
  /// colour so it reads as busy rather than disabled.
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    final color = !enabled
        ? BrandColors.grey400
        : destructive
            ? BrandColors.danger
            : BrandColors.ink;

    return Material(
      color: BrandColors.white,
      borderRadius: Corners.brMd,
      child: InkWell(
        onTap: loading ? null : onTap,
        borderRadius: Corners.brMd,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: Insets.md),
          child: Column(
            children: [
              if (loading)
                SizedBox.square(
                  dimension: 20,
                  child: Padding(
                    padding: const EdgeInsets.all(2),
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: color,
                    ),
                  ),
                )
              else
                Icon(icon, size: 20, color: color),
              const SizedBox(height: Insets.xs),
              Text(
                label,
                style: Theme.of(context)
                    .textTheme
                    .labelMedium
                    ?.copyWith(color: color),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Shown once the service ends, so the screen resolves rather than sitting on a
/// map that will never move again.
class _TerminalBody extends StatelessWidget {
  const _TerminalBody({required this.service});

  final Service service;

  @override
  Widget build(BuildContext context) {
    final completed = service.status == ServiceStatus.closed ||
        service.status == ServiceStatus.completed;

    return SafeArea(
      child: Column(
        children: [
          Expanded(
            child: EmptyState(
              title: completed ? 'Servicio completado' : 'Servicio cancelado',
              message: completed
                  ? 'Gracias por usar Grúas RD. Puedes ver la factura en tu '
                      'historial.'
                  : 'Este servicio fue cancelado. Puedes pedir otra grúa cuando '
                      'lo necesites.',
              icon: completed ? Icons.check_circle_outline : Icons.cancel_outlined,
              tone: completed ? EmptyStateTone.success : EmptyStateTone.neutral,
            ),
          ),
          // The moment the tow ends is when the customer remembers it best.
          if (completed)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Insets.gutter),
              child: RateDriverCard(service: service),
            ),
          Padding(
            padding: const EdgeInsets.all(Insets.gutter),
            child: Column(
              children: [
                ElevatedButton(
                  onPressed: () => context.go(Routes.home),
                  child: const Text('Volver al inicio'),
                ),
                const SizedBox(height: Insets.md),
                OutlinedButton(
                  onPressed: () => context.go(Routes.detailFor(service.id)),
                  child: const Text('Ver detalle y factura'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorBody extends StatelessWidget {
  const _ErrorBody({required this.message, required this.onBack});

  final String message;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Center(
        child: EmptyState(
          title: 'Algo salió mal',
          message: message,
          icon: Icons.error_outline,
          tone: EmptyStateTone.error,
          actionLabel: 'Ir al inicio',
          onAction: onBack,
        ),
      ),
    );
  }
}
