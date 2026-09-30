import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:grua_core/grua_core.dart';

import '../rating/rate_driver.dart';

/// One past service: the route, the timeline from the event log, the price
/// breakdown, and the invoice.
class ServiceDetailScreen extends ConsumerWidget {
  const ServiceDetailScreen({required this.serviceId, super.key});

  final String serviceId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final service = ref.watch(serviceByIdProvider(serviceId)).value;
    final events = ref.watch(serviceEventsProvider(serviceId)).value ?? const [];

    // The roads the tow took, rather than a line drawn over the mountains.
    final dropoff = service?.dropoff?.geo;
    final stored = service?.towPath ?? const <LatLng>[];
    final road = stored.isNotEmpty
        ? stored
        : service == null || dropoff == null
            ? null
            : ref.watch(roadRouteProvider((service.pickup.geo, dropoff))).value
                ?.points;

    return Scaffold(
      backgroundColor: BrandColors.offWhite,
      appBar: AppBar(
        leading: BackButton(onPressed: () => context.pop()),
        title: Text(service?.code ?? 'Servicio'),
      ),
      body: service == null
          ? const BrandLoader()
          : ListView(
              padding: const EdgeInsets.all(Insets.lg),
              children: [
                SizedBox(
                  height: 180,
                  child: ClipRRect(
                    borderRadius: Corners.brLg,
                    child: GruaMap(
                      center: service.pickup.geo,
                      hasApiKey: ref.watch(hasMapsKeyProvider),
                      zoom: 13,
                      interactive: false,
                      showAttribution: false,
                      expandable: true,
                      route: road ?? [service.pickup.geo, ?dropoff],
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
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: Insets.lg),

                FloatingCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              service.vehicle.displayName,
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                          ),
                          StatusChip(service.status, compact: true),
                        ],
                      ),
                      const SizedBox(height: Insets.md),
                      RouteSummary(
                        pickup: service.pickup.displayAddress,
                        pickupReference: service.pickup.reference,
                        dropoff: service.dropoff?.displayAddress,
                      ),
                      const Divider(height: Insets.xxl),
                      DetailRow(
                        label: 'Problema',
                        value: service.vehicle.condition.label,
                      ),
                      DetailRow(
                        label: 'Tipo de grúa',
                        value: service.truckTypeRequired.label,
                      ),
                      if (service.driverName.isNotEmpty)
                        DetailRow(label: 'Chofer', value: service.driverName),
                      if (service.truckPlate.isNotEmpty)
                        DetailRow(label: 'Placa', value: service.truckPlate),
                      DetailRow(
                        label: 'Distancia',
                        value: service.route.distanceLabel,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: Insets.lg),

                if (canRateDriver(service, DateTime.now().toUtc()) ||
                    (service.ratings.clientToDriver?.isRated ?? false)) ...[
                  RateDriverCard(service: service),
                  const SizedBox(height: Insets.lg),
                ],

                FloatingCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Desglose',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: Insets.sm),
                      for (final line in service.effectiveQuote.breakdown)
                        DetailRow(label: line.label, value: line.cents.formatDOP),
                      const Divider(),
                      DetailRow(
                        label: 'Total',
                        value: service.totalCents.formatDOP,
                        emphasise: true,
                      ),
                      DetailRow(
                        label: 'Forma de pago',
                        value: service.payment.method.label,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: Insets.lg),

                if (events.isNotEmpty) _Timeline(events: events),

                if (service.invoiceId != null) ...[
                  const SizedBox(height: Insets.lg),
                  _InvoiceCard(invoiceId: service.invoiceId!),
                ],
              ],
            ),
    );
  }
}

class _Timeline extends StatelessWidget {
  const _Timeline({required this.events});

  final List<ServiceEvent> events;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;

    return FloatingCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Historial del servicio', style: text.titleMedium),
          const SizedBox(height: Insets.lg),
          for (var i = 0; i < events.length; i++)
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Column(
                    children: [
                      Container(
                        width: 9,
                        height: 9,
                        margin: const EdgeInsets.only(top: 5),
                        decoration: const BoxDecoration(
                          color: BrandColors.red,
                          shape: BoxShape.circle,
                        ),
                      ),
                      if (i != events.length - 1)
                        Expanded(
                          child: Container(width: 1.5, color: BrandColors.grey200),
                        ),
                    ],
                  ),
                  const SizedBox(width: Insets.md),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: Insets.lg),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(events[i].description, style: text.bodyMedium),
                          if (events[i].at != null)
                            Text(
                              DoTime.dateAndTime(events[i].at!),
                              style: text.bodySmall
                                  ?.copyWith(color: BrandColors.grey600),
                            ),
                        ],
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

class _InvoiceCard extends ConsumerWidget {
  const _InvoiceCard({required this.invoiceId});

  final String invoiceId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;

    return FutureBuilder<Result<Invoice>>(
      future: ref.read(invoiceRepositoryProvider).fetchInvoice(invoiceId),
      builder: (context, snapshot) {
        final invoice = snapshot.data?.valueOrNull;
        if (invoice == null) return const SizedBox.shrink();

        return FloatingCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.receipt_long, color: BrandColors.red),
                  const SizedBox(width: Insets.md),
                  Expanded(child: Text('Factura', style: text.titleMedium)),
                ],
              ),
              const SizedBox(height: Insets.md),
              DetailRow(label: 'NCF', value: invoice.displayNcf),
              DetailRow(label: 'Tipo', value: invoice.ncfType.label),
              if (invoice.itbisCents > 0)
                DetailRow(
                  label: 'ITBIS',
                  value: invoice.itbisCents.formatDOP,
                ),
              DetailRow(
                label: 'Total',
                value: invoice.totalCents.formatDOP,
                emphasise: true,
              ),
              const SizedBox(height: Insets.md),
              OutlinedButton.icon(
                onPressed: () async {
                  final result = await ref
                      .read(invoiceRepositoryProvider)
                      .downloadUrl(invoiceId);
                  if (!context.mounted) return;
                  result.fold(
                    (url) => ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Abriendo $url')),
                    ),
                    (failure) => ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(failure.userMessage)),
                    ),
                  );
                },
                icon: const Icon(Icons.download_outlined, size: 18),
                label: const Text('Descargar factura'),
              ),
            ],
          ),
        );
      },
    );
  }
}
