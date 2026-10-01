import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:grua_core/grua_core.dart';

import '../evaluations/evaluation_widgets.dart';

/// Registered customers.
///
/// The office opens this list for three reasons: to find the person on the
/// phone, to check whether a company account bills with RNC, and to see who has
/// been blocked and why. The columns are those three questions and nothing
/// else — a customer's service history belongs on the service, not here.
class ClientsScreen extends ConsumerStatefulWidget {
  const ClientsScreen({super.key});

  @override
  ConsumerState<ClientsScreen> createState() => _ClientsScreenState();
}

/// What the roster can be narrowed to. Deliberately coarse: a dispatcher
/// filters to find someone, then reads the row.
enum _ClientFilter {
  all('Todos'),
  blocked('Bloqueados'),
  withRnc('Con RNC'),
  newThisMonth('Nuevos (30 días)');

  const _ClientFilter(this.label);

  final String label;
}

class _ClientsScreenState extends ConsumerState<ClientsScreen> {
  _ClientFilter _filter = _ClientFilter.all;
  String _query = '';

  /// How long a snapshot listener may stay silent before we stop calling it
  /// "loading" and start calling it "not connected".
  ///
  /// A Firestore stream that cannot reach the backend never errors — it just
  /// never emits — so nothing but a clock can tell the two apart. An empty
  /// collection answers in well under a second, so anything past this is a
  /// transport problem, not a slow query.
  static const _stallAfter = Duration(seconds: 12);

  Timer? _stallTimer;
  bool _stalled = false;

  @override
  void initState() {
    super.initState();
    _armStallTimer();
  }

  @override
  void dispose() {
    _stallTimer?.cancel();
    super.dispose();
  }

  void _armStallTimer() {
    _stallTimer?.cancel();
    _stalled = false;
    _stallTimer = Timer(_stallAfter, () {
      if (mounted) setState(() => _stalled = true);
    });
  }

  void _retry() {
    setState(_armStallTimer);
    ref.invalidate(allClientsProvider);
  }

  @override
  Widget build(BuildContext context) {
    // Anything at all from the stream — rows, an empty list, or an error —
    // means the connection is alive and the stall clock is no longer relevant.
    ref.listen<AsyncValue<List<AppUser>>>(allClientsProvider, (_, next) {
      if (next.isLoading) return;
      _stallTimer?.cancel();
      if (_stalled && mounted) setState(() => _stalled = false);
    });

    final clients = ref.watch(allClientsProvider);
    final text = Theme.of(context).textTheme;
    final palette = context.palette;
    final all = clients.value ?? const <AppUser>[];
    final filtered = _apply(all);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.all(Insets.xl),
          // A Wrap: on a 1024-px screen the search and the filter drop to a
          // second line instead of running off the edge.
          child: Wrap(
            spacing: Insets.lg,
            runSpacing: Insets.md,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('Clientes', style: text.headlineSmall),
                  const SizedBox(width: Insets.md),
                  Text(
                    all.isEmpty ? '' : '${all.length} registrados',
                    style: text.bodySmall?.copyWith(color: palette.textMuted),
                  ),
                ],
              ),
              SizedBox(
                width: 300,
                height: 38,
                child: TextField(
                  onChanged: (value) => setState(() => _query = value),
                  decoration: const InputDecoration(
                    hintText: 'Nombre, teléfono, correo o RNC',
                    prefixIcon: Icon(Icons.search, size: 18),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
              ),
              _FilterDropdown(
                value: _filter,
                onChanged: (value) => setState(() => _filter = value),
              ),
            ],
          ),
        ),
        Expanded(child: _body(clients, filtered, all.isEmpty)),
      ],
    );
  }

  Widget _body(
    AsyncValue<List<AppUser>> clients,
    List<AppUser> filtered,
    bool rosterEmpty,
  ) {
    // Loading and error are shown only while there is nothing to draw: once a
    // roster has arrived, a dropped stream should not blank the table out from
    // under whoever is reading it.
    if (rosterEmpty && clients.hasError) {
      final error = clients.error;
      return EmptyState(
        title: 'No se pudo cargar',
        message: error is Failure
            ? error.userMessage
            : 'La lista de clientes no está disponible ahora mismo.',
        icon: Icons.cloud_off_outlined,
        tone: EmptyStateTone.error,
        actionLabel: 'Reintentar',
        onAction: _retry,
      );
    }
    if (rosterEmpty && _stalled) {
      return EmptyState(
        title: 'Sin conexión con la base de datos',
        message: 'El panel no está recibiendo respuesta de Firestore. Suele '
            'ser la red de la oficina bloqueando la conexión con '
            'firestore.googleapis.com — revísala con el proveedor, o prueba '
            'sin VPN.',
        icon: Icons.cloud_off_outlined,
        tone: EmptyStateTone.error,
        actionLabel: 'Reintentar',
        onAction: _retry,
      );
    }
    if (rosterEmpty && clients.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (rosterEmpty) {
      return const EmptyState(
        title: 'Todavía no hay clientes',
        message: 'Las cuentas aparecen aquí en cuanto alguien se registra '
            'desde la app.',
        icon: Icons.people_outline,
      );
    }
    if (filtered.isEmpty) {
      return const EmptyState(
        title: 'Sin resultados',
        message: 'Ningún cliente coincide con esa búsqueda.',
        icon: Icons.search_off,
      );
    }
    return _ClientTable(clients: filtered);
  }

  List<AppUser> _apply(List<AppUser> clients) {
    final query = _query.trim().toLowerCase();
    // Phones are typed with dashes or spaces as often as not, so both sides of
    // the comparison are reduced to digits.
    final digits = query.replaceAll(RegExp(r'\D'), '');
    final monthAgo = DateTime.now().toUtc().subtract(const Duration(days: 30));

    return clients.where((client) {
      final matchesFilter = switch (_filter) {
        _ClientFilter.all => true,
        _ClientFilter.blocked => client.blocked,
        _ClientFilter.withRnc => client.billsWithRnc,
        _ClientFilter.newThisMonth =>
          client.createdAt != null && client.createdAt!.isAfter(monthAgo),
      };
      if (!matchesFilter) return false;
      if (query.isEmpty) return true;

      return client.name.toLowerCase().contains(query) ||
          client.email.toLowerCase().contains(query) ||
          client.rnc.contains(query) ||
          (digits.isNotEmpty &&
              client.phone.replaceAll(RegExp(r'\D'), '').contains(digits));
    }).toList();
  }
}

class _FilterDropdown extends StatelessWidget {
  const _FilterDropdown({required this.value, required this.onChanged});

  final _ClientFilter value;
  final ValueChanged<_ClientFilter> onChanged;

  @override
  Widget build(BuildContext context) {
    return DropdownButtonHideUnderline(
      child: DropdownButton<_ClientFilter>(
        value: value,
        onChanged: (next) => next == null ? null : onChanged(next),
        items: [
          for (final filter in _ClientFilter.values)
            DropdownMenuItem(value: filter, child: Text(filter.label)),
        ],
      ),
    );
  }
}

class _ClientTable extends StatelessWidget {
  const _ClientTable({required this.clients});

  final List<AppUser> clients;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final palette = context.palette;

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: Insets.xl),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minWidth: MediaQuery.sizeOf(context).width - 300,
          ),
          child: DataTable(
            headingRowColor: WidgetStatePropertyAll(palette.canvas),
            headingTextStyle: text.labelSmall,
            dividerThickness: 1,
            columns: const [
              DataColumn(label: Text('CLIENTE')),
              DataColumn(label: Text('CORREO')),
              DataColumn(label: Text('RNC')),
              DataColumn(label: Text('PAGO')),
              DataColumn(label: Text('SERVICIOS'), numeric: true),
              DataColumn(label: Text('CALIFICACIÓN')),
              DataColumn(label: Text('REGISTRADO')),
              DataColumn(label: Text('ESTADO')),
            ],
            rows: [
              for (final client in clients)
                DataRow(
                  cells: [
                    DataCell(
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            client.hasProfile ? client.name : 'Sin nombre',
                            style: text.titleSmall?.copyWith(
                              color: client.hasProfile
                                  ? palette.text
                                  : palette.textMuted,
                            ),
                          ),
                          Text(
                            client.displayPhone,
                            style: text.bodySmall
                                ?.copyWith(color: palette.textMuted),
                          ),
                        ],
                      ),
                    ),
                    DataCell(
                      Text(
                        client.email.isEmpty ? '—' : client.email,
                        style: client.email.isEmpty
                            ? text.bodyMedium
                                ?.copyWith(color: palette.textFaint)
                            : text.bodyMedium,
                      ),
                    ),
                    DataCell(
                      client.billsWithRnc
                          // The RNC is the whole reason this account bills as
                          // crédito fiscal, so the NCF type is spelled out.
                          ? Tooltip(
                              message: 'Factura con ${client.ncfType.label}',
                              child: Text(client.rnc),
                            )
                          : Text(
                              '—',
                              style: text.bodyMedium
                                  ?.copyWith(color: palette.textFaint),
                            ),
                    ),
                    DataCell(Text(client.preferredPaymentMethod.label)),
                    DataCell(Text('${client.completedServices}')),
                    DataCell(_ClientRatingCell(client: client)),
                    DataCell(
                      client.createdAt == null
                          ? Text(
                              '—',
                              style: text.bodyMedium
                                  ?.copyWith(color: palette.textFaint),
                            )
                          : Tooltip(
                              message: DoTime.dateAndTime(client.createdAt!),
                              child: Text(DoTime.fullDate(client.createdAt!)),
                            ),
                    ),
                    DataCell(_StatusPill(client: client)),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.client});

  final AppUser client;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;

    final (label, fg, bg) = switch (client) {
      _ when client.blocked =>
        ('Bloqueado', palette.danger, palette.dangerTint),
      // A phone-verified account with no name never finished registration, so
      // it cannot request yet. Worth seeing: it usually means the profile
      // screen was abandoned, not that the customer is inactive.
      _ when !client.hasProfile =>
        ('Sin completar', palette.warning, palette.warningTint),
      _ => ('Activo', palette.success, palette.successTint),
    };

    final pill = Container(
      padding: const EdgeInsets.symmetric(horizontal: Insets.sm, vertical: 3),
      decoration: BoxDecoration(color: bg, borderRadius: Corners.brXs),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(color: fg),
      ),
    );

    final reason = client.blockedReason.trim();
    if (client.blocked && reason.isNotEmpty) {
      return Tooltip(message: reason, child: pill);
    }
    return pill;
  }
}

/// How choferes rated this customer: stars, the average and how many ratings
/// it rests on.
class _ClientRatingCell extends StatelessWidget {
  const _ClientRatingCell({required this.client});

  final AppUser client;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final palette = context.palette;
    final count = client.ratingCount;
    if (count == 0) {
      return Text(
        'Sin calificar',
        key: Key('client-rating-${client.id}'),
        style: text.bodyMedium?.copyWith(color: palette.textMuted),
      );
    }
    final average = client.averageRating;
    return Column(
      key: Key('client-rating-${client.id}'),
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        RatingStars(value: average),
        const SizedBox(height: Insets.xxs),
        Text(
          '${average.toStringAsFixed(1)} · $count',
          style: text.bodySmall?.copyWith(color: palette.textMuted),
        ),
      ],
    );
  }
}
