import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:grua_core/grua_core.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../router.dart';
import '../notifications/notification_widgets.dart';
import 'proof_photos_sheet.dart';

/// The job in progress.
///
/// One primary action at a time — Llegué, then Iniciar servicio, then
/// Finalizar, then Cobrar — because a chofer holding a phone next to a
/// flatbed should never have to decide which of four buttons applies.
///
/// Every one of those actions is a server call with a guard behind it. The
/// screen shows the outcome, it does not decide it: "Llegué" from two
/// kilometres away is refused by `markArrived`, and the refusal tells the
/// chofer how far off they are rather than just failing.
class ActiveServiceScreen extends ConsumerStatefulWidget {
  const ActiveServiceScreen({super.key});

  @override
  ConsumerState<ActiveServiceScreen> createState() =>
      _ActiveServiceScreenState();
}

class _ActiveServiceScreenState extends ConsumerState<ActiveServiceScreen> {
  var _busy = false;

  /// Photos already uploaded for a transition the server then refused — "Estás
  /// a 2.3 km del destino" — kept so trying again does not mean shooting the
  /// whole vehicle a second time.
  final _proof = <(String, ServicePhotoStage), List<String>>{};

  Future<void> _run(Future<Result<void>> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    final result = await action();
    if (!mounted) return;
    setState(() => _busy = false);

    if (result case Err(:final failure)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(failure.userMessage),
          backgroundColor: BrandColors.danger,
        ),
      );
    }
  }

  /// The chofer's own position: the phone's GPS first, then the last position
  /// the server mirrored, then the pickup itself
  /// so the range guards still have something to judge.
  LatLng _currentPosition(Service service) {
    final mine = ref.read(myPositionProvider).value?.position;
    if (mine != null) return mine;
    final tracking = ref.read(serviceTrackingProvider(service.id)).value;
    return tracking?.position ?? service.pickup.geo;
  }

  Future<void> _advance(Service service) async {
    final gateway = ref.read(functionsGatewayProvider);

    switch (service.status) {
      case ServiceStatus.accepted:
        await _run(() => gateway.markArrived(
              serviceId: service.id,
              position: _currentPosition(service),
            ));
      case ServiceStatus.arrived:
        final photos = await _proofPhotos(service, ServicePhotoStage.pickup);
        if (photos == null || !mounted) return;
        await _run(() => gateway.startService(
              serviceId: service.id,
              photoPaths: photos,
            ));
      case ServiceStatus.inProgress:
        await _finish(service);
      // An insurer's tow closes by itself: there is nothing to collect.
      case ServiceStatus.completed when !service.isInsurerJob:
        await _collectCash(service);
      case _:
        break;
    }
  }

  /// The photos for [stage]: the ones a refused attempt already uploaded, or
  /// fresh ones from the camera. Null when the chofer backs out.
  Future<List<String>?> _proofPhotos(
    Service service,
    ServicePhotoStage stage,
  ) async {
    final kept = _proof[(service.id, stage)];
    if (kept != null) return kept;
    final taken = await captureProofPhotos(
      context,
      serviceId: service.id,
      stage: stage,
    );
    if (taken != null) _proof[(service.id, stage)] = taken;
    return taken;
  }

  /// "Finalizar": the drop-off photos double as the confirmation that the
  /// vehicle is at the destination — nobody photographs a handover that has
  /// not happened.
  Future<void> _finish(Service service) async {
    final photos = await _proofPhotos(service, ServicePhotoStage.dropoff);
    if (photos == null || !mounted) return;

    await _run(() => ref.read(functionsGatewayProvider).completeService(
          serviceId: service.id,
          position: _currentPosition(service),
          photoPaths: photos,
        ));
  }

  Future<void> _collectCash(Service service) async {
    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => _CashSheet(amountCents: service.totalCents),
    );
    if (confirmed != true || !mounted) return;

    await _run(() => ref.read(functionsGatewayProvider).confirmCashCollected(
          serviceId: service.id,
          amountCents: service.totalCents,
        ));
  }

  @override
  Widget build(BuildContext context) {
    final service = ref.watch(activeDriverServiceProvider).value;
    if (service == null) return const Scaffold(body: BrandLoader());

    final tracking = ref.watch(serviceTrackingProvider(service.id)).value;
    final text = Theme.of(context).textTheme;

    return Scaffold(
      backgroundColor: BrandColors.redDeep,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Insets.lg),
              child: Row(
                children: [
                  const GruaLogo(size: 62),
                  const SizedBox(width: Insets.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'EN SERVICIO',
                          style: text.titleMedium?.copyWith(
                            color: BrandColors.white,
                            letterSpacing: 1.2,
                          ),
                        ),
                        Text(
                          service.code,
                          style: text.bodySmall
                              ?.copyWith(color: Colors.white70),
                        ),
                      ],
                    ),
                  ),
                  StatusChip(service.status, compact: true),
                  // During a job is when the customer writes, so the bell
                  // comes along onto this screen.
                  const NotificationBell(onDark: true),
                ],
              ),
            ),
            const SizedBox(height: Insets.md),
            Expanded(
              child: Container(
                width: double.infinity,
                decoration: const BoxDecoration(
                  color: BrandColors.offWhite,
                  borderRadius: Corners.sheet,
                ),
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(
                    Insets.lg,
                    Insets.xl,
                    Insets.lg,
                    Insets.lg,
                  ),
                  children: [
                    _ServiceMap(service: service, tracking: tracking),
                    const SizedBox(height: Insets.lg),
                    _ClientCard(service: service),
                    const SizedBox(height: Insets.lg),
                    _JobCard(service: service),
                    if (service.status == ServiceStatus.arrived) ...[
                      // Waiting is not billed to an insurance company.
                      if (!service.isInsurerJob) ...[
                        const SizedBox(height: Insets.lg),
                        _WaitingCard(service: service),
                      ],
                      const SizedBox(height: Insets.md),
                      _PaymentNotice(service: service),
                    ],
                    const SizedBox(height: Insets.xl),
                    _PrimaryAction(
                      service: service,
                      busy: _busy,
                      onPressed: () => _advance(service),
                    ),
                    if (service.isInsurerJob &&
                        service.status == ServiceStatus.completed) ...[
                      const SizedBox(height: Insets.sm),
                      const _InsurerClosingHint(),
                    ],
                    const SizedBox(height: Insets.md),
                    _CancelButton(service: service, busy: _busy, onRun: _run),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The job on a map: where the chofer is, and the road to where they are
/// going next.
///
/// Before "Llegué" the next stop is the customer, and the tow is drawn dashed
/// after it; once the vehicle is loaded the next stop is the destination.
/// "Abrir en Google Maps" hands the same stop to real turn-by-turn navigation,
/// which is what a chofer actually drives by.
class _ServiceMap extends ConsumerWidget {
  const _ServiceMap({required this.service, required this.tracking});

  final Service service;
  final ServiceTracking? tracking;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mine = ref.watch(myPositionProvider).value;
    final me = mine?.position ?? tracking?.position;

    final pickup = service.pickup.geo;
    final dropoff = service.dropoff?.geo;
    final goingToPickup = service.status == ServiceStatus.accepted;
    final next = goingToPickup ? pickup : (dropoff ?? pickup);

    final toNext = me == null
        ? null
        : ref.watch(roadRouteProvider((routeGrain(me), next))).value;
    // The path the server already routed, where there is one.
    final storedTow = service.towPath;
    final tow = !goingToPickup || dropoff == null
        ? null
        : storedTow.isNotEmpty
            ? storedTow
            : ref.watch(roadRouteProvider((pickup, dropoff))).value?.points;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 280,
          child: ClipRRect(
            borderRadius: Corners.brLg,
            child: GruaMap(
              center: me ?? next,
              hasApiKey: ref.watch(hasMapsKeyProvider),
              zoom: 14,
              showAttribution: false,
              expandable: true,
              fitTo: [
                ?me,
                next,
                if (goingToPickup) ?dropoff,
              ],
              routes: [
                if (tow != null)
                  MapRoute(points: tow, color: BrandColors.ink, dashed: true),
                if (toNext != null)
                  MapRoute(points: toNext.points, dashed: toNext.isApproximate),
                // Without a position yet, the plain trip still reads — but
                // only when the road is not already drawn, or it is a straight
                // copy laid over it.
                if (me == null && tow == null && dropoff != null)
                  MapRoute(points: [pickup, dropoff], color: BrandColors.ink, dashed: true),
              ],
              // Red for you, blue for the customer, black for the destination.
              markers: [
                MapMarker(position: pickup, kind: MapMarkerKind.customer, label: 'Cliente'),
                if (dropoff != null)
                  MapMarker(position: dropoff, kind: MapMarkerKind.dropoff, label: 'Destino'),
                if (me != null)
                  MapMarker(position: me, kind: MapMarkerKind.me, label: 'Tú'),
              ],
            ),
          ),
        ),
        const SizedBox(height: Insets.sm),
        Row(
          children: [
            Expanded(
              child: Text(
                toNext == null
                    ? (goingToPickup ? 'Hacia el cliente' : 'Hacia el destino')
                    : '${goingToPickup ? 'Al cliente' : 'Al destino'}: '
                        '${toNext.distanceLabel} · ${toNext.durationLabel}'
                        '${toNext.isApproximate ? ' (aprox.)' : ''}',
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: BrandColors.grey800),
              ),
            ),
            TextButton.icon(
              onPressed: () => unawaited(_navigate(context, next)),
              icon: const Icon(Icons.navigation_outlined, size: 18),
              label: const Text('Abrir en Google Maps'),
            ),
          ],
        ),
      ],
    );
  }

  /// Turn-by-turn to [to] in Google Maps: the app on a phone, the site on the
  /// web. The universal URL works for both.
  Future<void> _navigate(BuildContext context, LatLng to) async {
    final url = Uri.https('www.google.com', '/maps/dir/', {
      'api': '1',
      'destination': '${to.latitude},${to.longitude}',
      'travelmode': 'driving',
    });
    final messenger = ScaffoldMessenger.of(context);
    final opened = await launchUrl(url, mode: LaunchMode.externalApplication);
    if (!opened) {
      messenger.showSnackBar(
        const SnackBar(content: Text('No se pudo abrir Google Maps.')),
      );
    }
  }
}

class _ClientCard extends ConsumerWidget {
  const _ClientCard({required this.service});

  final Service service;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    final unread = ref.watch(unreadMessageCountProvider(service.id));

    return FloatingCard(
      child: Row(
        children: [
          CircleAvatar(
            radius: 22,
            backgroundColor: BrandColors.redTint,
            child: Text(
              service.clientName.isEmpty ? '?' : service.clientName[0],
              style: text.titleMedium?.copyWith(color: BrandColors.red),
            ),
          ),
          const SizedBox(width: Insets.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  service.clientName.isEmpty && service.isInsurerJob
                      ? 'Asegurado'
                      : service.clientName,
                  style: text.titleSmall,
                ),
                Text(
                  service.isInsurerJob
                      ? 'Asegurado de ${service.insurerName.isEmpty ? 'la aseguradora' : service.insurerName}'
                      : service.clientPhone,
                  style: text.bodySmall?.copyWith(color: BrandColors.grey600),
                ),
              ],
            ),
          ),
          if (service.isInsurerJob && service.clientPhone.isNotEmpty)
            IconButton.filledTonal(
              key: const Key('insured-call'),
              tooltip: 'Llamar al asegurado',
              // The insured has no app to ring: a plain phone call.
              onPressed: () => unawaited(
                launchUrl(Uri(scheme: 'tel', path: service.clientPhone)),
              ),
              icon: const Icon(Icons.call, size: 20),
            ),
          if (service.canChat)
            IconButton.filledTonal(
              key: const Key('client-chat'),
              tooltip: 'Chat con el cliente',
              onPressed: () => context.push(Routes.chatFor(service.id)),
              icon: Badge.count(
                count: unread,
                isLabelVisible: unread > 0,
                backgroundColor: BrandColors.red,
                textColor: BrandColors.white,
                child: const Icon(Icons.chat_bubble_outline, size: 20),
              ),
            ),
          // Room between the two, so a thumb aiming for one at the roadside
          // does not land on the other.
          if (service.canChat && service.canCall)
            const SizedBox(width: Insets.sm),
          if (service.canCall) ...[
            IconButton.filledTonal(
              key: const Key('client-call'),
              tooltip: 'Llamar al cliente',
              // An in-app voice call: rings the customer's app, and works in
              // a browser as well as on a phone.
              onPressed: () => unawaited(
                ref.read(callControllerProvider.notifier).call(
                      serviceId: service.id,
                      peerName: service.clientName,
                    ),
              ),
              icon: const Icon(Icons.call, size: 20),
            ),
            const SizedBox(width: Insets.sm),
            IconButton.filledTonal(
              key: const Key('client-video-call'),
              tooltip: 'Videollamada',
              // The same in-app call as the phone button, with the camera on:
              // the customer can show the damage before the grúa gets there.
              onPressed: () => unawaited(
                ref.read(callControllerProvider.notifier).call(
                      serviceId: service.id,
                      peerName: service.clientName,
                      video: true,
                    ),
              ),
              icon: const Icon(Icons.videocam_outlined, size: 20),
            ),
          ],
        ],
      ),
    );
  }
}

class _JobCard extends StatelessWidget {
  const _JobCard({required this.service});

  final Service service;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;

    return FloatingCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(service.vehicle.displayName, style: text.titleSmall),
          Text(
            service.isInsurerJob
                ? [
                    if (service.vehicle.plate.isNotEmpty) service.vehicle.plate,
                    if (service.vehicle.color.isNotEmpty) service.vehicle.color,
                  ].join(' · ')
                : service.vehicle.condition.label,
            style: text.bodySmall?.copyWith(color: BrandColors.grey600),
          ),
          if (service.insurance case final claim?
              when claim.claimNumber.isNotEmpty) ...[
            const SizedBox(height: Insets.xs),
            Text(
              'Siniestro ${claim.claimNumber}',
              key: const Key('job-claim'),
              style: text.bodySmall?.copyWith(fontWeight: FontWeight.w600),
            ),
          ],
          // The customer's photos stay to hand on the way, for picking the
          // right car out of a row of them.
          if (service.vehicle.photoPaths.isNotEmpty) ...[
            const SizedBox(height: Insets.sm),
            VehiclePhotoStrip(
              key: const Key('job-vehicle-photos'),
              urls: service.vehicle.photoPaths,
            ),
          ],
          const Divider(height: Insets.xxl),
          RouteSummary(
            pickup: service.pickup.displayAddress,
            pickupReference: service.pickup.reference,
            dropoff: service.dropoff?.displayAddress,
          ),
          const Divider(height: Insets.xxl),
          if (service.isInsurerJob)
            Row(
              key: const Key('job-billed-to-insurer'),
              children: [
                const Icon(
                  Icons.business_outlined,
                  size: 18,
                  color: BrandColors.grey600,
                ),
                const SizedBox(width: Insets.sm),
                Expanded(
                  child: Text(
                    'Lo paga ${service.insurerName.isEmpty ? 'la aseguradora' : service.insurerName} · no cobres al cliente',
                    style: text.bodyMedium,
                  ),
                ),
              ],
            )
          else
            Row(
              children: [
                const Icon(
                  Icons.payments_outlined,
                  size: 18,
                  color: BrandColors.grey600,
                ),
                const SizedBox(width: Insets.sm),
                Expanded(
                  child: Text(
                    _paymentLine(service.payment),
                    style: text.bodyMedium,
                  ),
                ),
                Text(service.totalCents.formatDOP, style: text.titleMedium),
              ],
            ),
          _EarningsLine(serviceId: service.id),
        ],
      ),
    );
  }
}

String _paymentLine(ServicePayment payment) =>
    payment.isPaid ? payment.status.label : 'Cobrar en efectivo';

/// "Ganancia por este servicio": what the chofer takes home, from their own
/// offer. Nothing on a job the office assigned by hand, which has no offer.
class _EarningsLine extends ConsumerWidget {
  const _EarningsLine({required this.serviceId});

  final String serviceId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final offer = ref.watch(myOfferProvider(serviceId)).value;
    final net = offer?.netEarningsCents ?? 0;
    if (net <= 0) return const SizedBox.shrink();

    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(top: Insets.sm),
      child: Row(
        key: const Key('job-earnings'),
        children: [
          const Icon(
            Icons.account_balance_wallet_outlined,
            size: 18,
            color: BrandColors.red,
          ),
          const SizedBox(width: Insets.sm),
          Expanded(
            child: Text('Ganancia por este servicio', style: text.bodyMedium),
          ),
          Text(
            net.formatDOP,
            style: text.titleMedium?.copyWith(color: BrandColors.red),
          ),
        ],
      ),
    );
  }
}

/// What the chofer collects when the tow ends, while they wait to load.
///
/// Nothing is waiting on it: the money changes hands in cash at the end, so
/// this is a reminder of the amount, not a gate on starting.
class _PaymentNotice extends StatelessWidget {
  const _PaymentNotice({required this.service});

  final Service service;

  @override
  Widget build(BuildContext context) => service.isInsurerJob
      ? InlineNotice(
          key: const Key('payment-insurer'),
          tone: NoticeTone.info,
          icon: Icons.business_outlined,
          message: 'Servicio de aseguradora: no cobres nada al cliente. '
              'Se factura a ${service.insurerName.isEmpty ? 'la aseguradora' : service.insurerName}.',
        )
      : InlineNotice(
          key: const Key('payment-ready'),
          tone: NoticeTone.success,
          icon: Icons.payments_outlined,
          message: 'Cobrarás ${service.totalCents.formatDOP} en efectivo al '
              'terminar.',
        );
}

/// Live waiting clock, with what it will cost the customer.
class _WaitingCard extends ConsumerWidget {
  const _WaitingCard({required this.service});

  final Service service;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pricing = ref.watch(pricingConfigProvider).value;
    final arrivedAt = service.timeline.arrivedAt;
    if (arrivedAt == null || pricing == null) return const SizedBox.shrink();

    return StreamBuilder<void>(
      stream: Stream<void>.periodic(const Duration(seconds: 1)),
      builder: (context, _) {
        final elapsed = DateTime.now().toUtc().difference(arrivedAt);
        final free = Duration(minutes: pricing.freeWaitingMinutes);
        final over = elapsed - free;
        final chargeable = over.isNegative ? 0 : over.inMinutes;

        return InlineNotice(
          icon: Icons.timer_outlined,
          tone: chargeable > 0 ? NoticeTone.warning : NoticeTone.info,
          message: chargeable > 0
              ? 'Espera ${DoTime.stopwatch(elapsed)} · se cobrarán '
                  '${(chargeable * pricing.perWaitingMinuteCents).formatDOP}'
              : 'Espera ${DoTime.stopwatch(elapsed)} · '
                  '${pricing.freeWaitingMinutes} min sin cargo',
        );
      },
    );
  }
}

/// An insurer's finished tow closes on its own. If it has not, the office
/// sweeps it within minutes — and the chofer is told whom to call meanwhile.
class _InsurerClosingHint extends ConsumerWidget {
  const _InsurerClosingHint();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    final phone = ref.watch(appSettingsProvider).value?.supportPhone ?? '';
    return Column(
      key: const Key('insurer-closing-hint'),
      children: [
        Text(
          'La aseguradora paga este servicio; no hay nada que cobrar. Se cierra '
          'solo en unos minutos. Si no se cierra, llama a la oficina.',
          textAlign: TextAlign.center,
          style: text.bodySmall?.copyWith(color: BrandColors.grey600),
        ),
        if (phone.isNotEmpty)
          TextButton.icon(
            key: const Key('call-office'),
            onPressed: () async {
              final messenger = ScaffoldMessenger.of(context);
              final opened = await launchUrl(Uri(scheme: 'tel', path: phone));
              if (!opened) {
                messenger.showSnackBar(
                  const SnackBar(content: Text('No se pudo iniciar la llamada.')),
                );
              }
            },
            icon: const Icon(Icons.phone_outlined),
            label: const Text('Llamar a la oficina'),
          ),
      ],
    );
  }
}

/// One button, whose label and colour follow the state machine.
class _PrimaryAction extends StatelessWidget {
  const _PrimaryAction({
    required this.service,
    required this.busy,
    required this.onPressed,
  });

  final Service service;
  final bool busy;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (service.status) {
      ServiceStatus.accepted => ('LLEGUÉ', BrandColors.red),
      ServiceStatus.arrived => ('INICIAR SERVICIO', BrandColors.red),
      ServiceStatus.inProgress => ('FINALIZAR SERVICIO', BrandColors.ink),
      // An insurer's tow closes on its own a moment after this.
      ServiceStatus.completed when service.isInsurerJob => (
          'SERVICIO COMPLETADO',
          BrandColors.success,
        ),
      ServiceStatus.completed => (
          'COBRADO EN EFECTIVO ${service.totalCents.formatDOP}',
          BrandColors.success,
        ),
      _ => ('ESPERANDO…', BrandColors.grey400),
    };

    final enabled = !busy &&
        !(service.isInsurerJob && service.status == ServiceStatus.completed) &&
        const {
          ServiceStatus.accepted,
          ServiceStatus.arrived,
          ServiceStatus.inProgress,
          ServiceStatus.completed,
        }.contains(service.status);

    return ElevatedButton(
      onPressed: enabled ? onPressed : null,
      style: ElevatedButton.styleFrom(
        backgroundColor: color,
        minimumSize: const Size.fromHeight(62),
        shape: const RoundedRectangleBorder(borderRadius: Corners.brLg),
      ),
      child: busy
          ? const SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(
                strokeWidth: 2.4,
                color: BrandColors.white,
              ),
            )
          : Text(label),
    );
  }
}

class _CancelButton extends ConsumerWidget {
  const _CancelButton({
    required this.service,
    required this.busy,
    required this.onRun,
  });

  final Service service;
  final bool busy;
  final Future<void> Function(Future<Result<void>> Function()) onRun;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Once the vehicle is loaded, dropping the job is an operations problem,
    // not a button.
    if (service.status == ServiceStatus.inProgress ||
        service.status == ServiceStatus.completed) {
      return const SizedBox.shrink();
    }

    return TextButton(
      onPressed: busy
          ? null
          : () async {
              final reason = await showModalBottomSheet<DriverCancelReason>(
                context: context,
                // Seven reasons are taller than the default half-screen sheet,
                // which cut the last ones off. The sheet sizes to its list and
                // scrolls only when even the full screen is not enough.
                isScrollControlled: true,
                useSafeArea: true,
                backgroundColor: Colors.transparent,
                builder: (_) => const _ReasonSheet(),
              );
              if (reason == null) return;
              await onRun(
                () => ref.read(functionsGatewayProvider).cancelByDriver(
                      serviceId: service.id,
                      reason: reason,
                    ),
              );
            },
      style: TextButton.styleFrom(foregroundColor: BrandColors.danger),
      child: const Text('No puedo hacer este servicio'),
    );
  }
}

/// Fixed reasons only — these feed the admin's abuse flags, and free text
/// cannot be counted.
class _ReasonSheet extends StatelessWidget {
  const _ReasonSheet();

  @override
  Widget build(BuildContext context) {
    const reasons = [
      DriverCancelReason.vehicleBreakdown,
      DriverCancelReason.wrongTruckType,
      DriverCancelReason.clientNotPresent,
      DriverCancelReason.clientRefused,
      DriverCancelReason.inaccessibleLocation,
      DriverCancelReason.unsafeLocation,
      DriverCancelReason.emergency,
    ];

    return BottomActionSheet(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '¿Por qué no puedes hacerlo?',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: Insets.md),
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final reason in reasons)
                    ListTile(
                      title: Text(reason.label),
                      onTap: () => Navigator.of(context).pop(reason),
                      trailing: const Icon(Icons.chevron_right,
                          color: BrandColors.grey400),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The amount to collect, in the largest type on the screen, with change from
/// the notes a Dominican customer actually hands over.
class _CashSheet extends StatelessWidget {
  const _CashSheet({required this.amountCents});

  final int amountCents;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final usefulBills = Money.commonBillsCents
        .where((bill) => bill >= amountCents)
        .take(3)
        .toList();

    return BottomActionSheet(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Center(child: FieldLabel('Cobrado en efectivo')),
          const SizedBox(height: Insets.md),
          Center(
            child: Text(
              amountCents.formatDOP,
              style: text.displaySmall?.copyWith(color: BrandColors.red),
            ),
          ),
          const SizedBox(height: Insets.xl),
          if (usefulBills.isNotEmpty) ...[
            const FieldLabel('Devuelta'),
            const SizedBox(height: Insets.sm),
            for (final bill in usefulBills)
              DetailRow(
                label: 'Si paga con ${bill.formatDOPCompact}',
                value: (bill - amountCents).formatDOP,
              ),
            const SizedBox(height: Insets.lg),
          ],
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('RECIBÍ EL EFECTIVO'),
          ),
          const SizedBox(height: Insets.sm),
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Todavía no'),
          ),
        ],
      ),
    );
  }
}
