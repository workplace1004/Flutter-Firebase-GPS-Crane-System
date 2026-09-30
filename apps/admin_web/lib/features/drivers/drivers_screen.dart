import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:grua_core/grua_core.dart';

import '../evaluations/evaluation_widgets.dart';
import '../shared/toast.dart';
import '../verification/license_verification_screen.dart';
import 'create_driver_dialog.dart';
import 'driver_details_dialog.dart';
import 'driver_status_dialog.dart';

/// Fleet roster.
///
/// The columns are the ones the office actually acts on: whether the chofer can
/// work, whether they are online right now, how often they take offers, and how
/// much collected cash they are still holding. Acceptance rate and cash owed are
/// the two numbers that start conversations.
class DriversScreen extends ConsumerStatefulWidget {
  const DriversScreen({super.key});

  @override
  ConsumerState<DriversScreen> createState() => _DriversScreenState();
}

class _DriversScreenState extends ConsumerState<DriversScreen> {
  DriverStatus? _filter;

  /// Shows only the choferes archived before "Eliminar" deleted for good, so
  /// the office can finish removing them.
  var _archived = false;
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final roster = ref.watch(allDriversProvider);
    final text = Theme.of(context).textTheme;

    // Choferes archived before deletion was permanent are kept apart.
    final drivers = (roster.value ?? const <Driver>[])
        .where((d) => d.archived == _archived)
        .toList();

    final query = _query.trim().toLowerCase();
    final filtered = drivers.where((d) {
      if (_filter != null && d.status != _filter) return false;
      if (query.isEmpty) return true;
      return d.name.toLowerCase().contains(query) ||
          d.cedula.contains(query) ||
          d.assignedTruckPlate.toLowerCase().contains(query);
    }).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.all(Insets.xl),
          child: Row(
            children: [
              // The title, the search and the filter share whatever is left
              // over once the action has its place, and drop to a second line
              // on a 1024-px screen rather than off the edge of it.
              Expanded(
                child: Wrap(
                  spacing: Insets.lg,
                  runSpacing: Insets.md,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text('Choferes', style: text.headlineSmall),
                    SizedBox(
                      width: 260,
                      height: 38,
                      child: TextField(
                        onChanged: (value) => setState(() => _query = value),
                        decoration: const InputDecoration(
                          hintText: 'Nombre, cédula o placa',
                          prefixIcon: Icon(Icons.search, size: 18),
                          contentPadding: EdgeInsets.zero,
                        ),
                      ),
                    ),
                    _StatusFilter(
                      value: _filter,
                      archived: _archived,
                      onChanged: (value, {archived = false}) => setState(() {
                        _filter = value;
                        _archived = archived;
                      }),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: Insets.md),
              ElevatedButton.icon(
                onPressed: () => unawaited(_createDriver(context)),
                style: ElevatedButton.styleFrom(
                  minimumSize: const Size(0, 40),
                  padding: const EdgeInsets.symmetric(horizontal: Insets.lg),
                ),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Nuevo chofer'),
              ),
            ],
          ),
        ),
        Expanded(child: _body(roster, drivers, filtered)),
      ],
    );
  }

  Widget _body(
    AsyncValue<List<Driver>> roster,
    List<Driver> drivers,
    List<Driver> filtered,
  ) {
    // Loading and error only take over before the first roster arrives: once
    // it has, a dropped stream should not blank the table out from under
    // whoever is reading it.
    if (!roster.hasValue) {
      if (roster.hasError) {
        final error = roster.error;
        return EmptyState(
          title: 'No se pudo cargar',
          message: error is Failure
              ? error.userMessage
              : 'La lista de choferes no está disponible ahora mismo.',
          icon: Icons.cloud_off_outlined,
          tone: EmptyStateTone.error,
          actionLabel: 'Reintentar',
          onAction: () => ref.invalidate(allDriversProvider),
        );
      }
      return const BrandLoader(message: 'Cargando choferes…');
    }

    if (drivers.isEmpty && _archived) {
      return const EmptyState(
        title: 'No hay choferes archivados',
        message: 'Los choferes eliminados ahora se borran por completo.',
        icon: Icons.inventory_2_outlined,
      );
    }
    if (drivers.isEmpty) {
      return const EmptyState(
        title: 'Todavía no hay choferes',
        message:
            'Crea el primero con "Nuevo chofer", o espera a que alguien '
            'se registre desde la app.',
        icon: Icons.badge_outlined,
      );
    }
    if (filtered.isEmpty) {
      return const EmptyState(
        title: 'Sin resultados',
        message: 'Ningún chofer coincide con ese filtro.',
        icon: Icons.search_off,
      );
    }
    return _DriverTable(
      drivers: filtered,
      // Empty until `/presence` answers: everyone reads as disconnected for a
      // moment, which is better than the roster waiting on a second stream.
      appOpen: ref.watch(connectedDriverIdsProvider).value ?? const {},
      onView: (driver) => unawaited(_viewDriver(driver)),
      onEdit: (driver) => unawaited(_editDriver(driver)),
      onDelete: (driver) => unawaited(_deleteDriver(driver)),
      onChangeStatus: (driver, target) =>
          unawaited(_changeStatus(driver, target)),
    );
  }

  Future<void> _createDriver(BuildContext context) async {
    final driverId = await showCreateDriverDialog(context);
    if (driverId == null || !context.mounted) return;

    // The roster is a live query, so the new chofer is already in the table.
    // Clearing the filters is what makes that visible: a new account is
    // inactive, which the "Activos" filter would otherwise hide.
    setState(() {
      _filter = null;
      _archived = false;
      _query = '';
    });
  }

  Future<void> _viewDriver(Driver driver) => showDriverDetailsDialog(
    context,
    driver,
    onEdit: () => unawaited(_editDriver(driver)),
    onChangeStatus: (target) => unawaited(_changeStatus(driver, target)),
  );

  /// Activates, deactivates or suspends [driver] after the office confirms.
  ///
  /// The roster is live, so the new status pill appears without anything done
  /// here beyond reporting how it went.
  Future<void> _changeStatus(Driver driver, DriverStatus target) async {
    final toast = Toaster.of(context);

    // The server refuses this too; saying so first saves typing a reason for
    // a change that cannot happen.
    if (!target.canWork && driver.isBusy) {
      toast.show(
        'Este chofer tiene un servicio en curso. Reasígnalo primero.',
        tone: ToastTone.error,
      );
      return;
    }

    final reason = await showDriverStatusDialog(context, driver, target);
    if (reason == null || !mounted) return;

    final result = await ref
        .read(functionsGatewayProvider)
        .setDriverStatus(driverId: driver.id, status: target, reason: reason);
    toast.show(
      result.isErr
          ? result.failureOrNull?.userMessage ??
                'No se pudo cambiar el estado del chofer.'
          : switch (target) {
              DriverStatus.active => '${driver.name} ya puede trabajar.',
              DriverStatus.suspended => '${driver.name} fue suspendido.',
              _ => '${driver.name} quedó inactivo.',
            },
      tone: result.isErr ? ToastTone.error : ToastTone.success,
    );
  }

  // The roster is live, so a saved edit shows up without anything done here.
  Future<void> _editDriver(Driver driver) =>
      showEditDriverDialog(context, driver);

  /// Deletes for good: login, record, papers and photos, freeing the email
  /// and the cédula. Past services and cortes stay as the company's history.
  Future<void> _deleteDriver(Driver driver) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('¿Eliminar a ${driver.name}?'),
        content: const Text(
          'Se borran para siempre su cuenta, sus datos, su licencia y sus '
          'fotos. Su correo y su cédula quedan libres para un registro nuevo. '
          'Sus servicios y cortes anteriores se conservan en el historial. '
          'Esto no se puede deshacer.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancelar'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(
              foregroundColor: context.palette.danger,
            ),
            child: const Text('Eliminar'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final toast = Toaster.of(context);
    final result = await ref
        .read(functionsGatewayProvider)
        .deleteDriver(driver.id);
    toast.show(
      result.isErr
          ? result.failureOrNull?.userMessage ??
                'No se pudo eliminar al chofer.'
          : '${driver.name} fue eliminado.',
      tone: result.isErr ? ToastTone.error : ToastTone.success,
    );
  }
}

class _StatusFilter extends StatelessWidget {
  const _StatusFilter({
    required this.value,
    required this.archived,
    required this.onChanged,
  });

  final DriverStatus? value;
  final bool archived;
  final void Function(DriverStatus? value, {bool archived}) onChanged;

  /// "Archivados" is not a status, so the menu keys on a string.
  static const _archivedKey = 'archived';

  @override
  Widget build(BuildContext context) {
    return DropdownButtonHideUnderline(
      child: DropdownButton<String>(
        value: archived ? _archivedKey : (value?.wire ?? 'all'),
        onChanged: (key) => key == _archivedKey
            ? onChanged(null, archived: true)
            : onChanged(key == 'all' ? null : DriverStatus.fromWire(key)),
        items: [
          const DropdownMenuItem(value: 'all', child: Text('Todos')),
          DropdownMenuItem(
            value: DriverStatus.active.wire,
            child: const Text('Activos'),
          ),
          DropdownMenuItem(
            value: DriverStatus.inactive.wire,
            child: const Text('Inactivos'),
          ),
          DropdownMenuItem(
            value: DriverStatus.suspended.wire,
            child: const Text('Suspendidos'),
          ),
          const DropdownMenuItem(
            value: _archivedKey,
            child: Text('Archivados'),
          ),
        ],
      ),
    );
  }
}

class _DriverTable extends StatelessWidget {
  const _DriverTable({
    required this.drivers,
    required this.appOpen,
    required this.onView,
    required this.onEdit,
    required this.onDelete,
    required this.onChangeStatus,
  });

  final List<Driver> drivers;

  /// Ids of the choferes with the app open right now.
  final Set<String> appOpen;
  final ValueChanged<Driver> onView;
  final ValueChanged<Driver> onEdit;
  final ValueChanged<Driver> onDelete;
  final void Function(Driver driver, DriverStatus target) onChangeStatus;

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
            // Room for the avatar beside the three-line name cell.
            dataRowMinHeight: 68,
            dataRowMaxHeight: 72,
            // Tighter than the default 56, so the actions column fits a laptop
            // screen instead of sitting past a sideways scroll.
            columnSpacing: 28,
            headingRowColor: WidgetStatePropertyAll(palette.canvas),
            headingTextStyle: text.labelSmall,
            dividerThickness: 1,
            columns: const [
              DataColumn(label: Text('CHOFER')),
              DataColumn(label: Text('CÉDULA')),
              DataColumn(label: Text('GRÚA')),
              DataColumn(label: Text('ESTADO')),
              DataColumn(label: Text('CALIFICACIÓN')),
              DataColumn(label: Text('ACEPTA'), numeric: true),
              DataColumn(label: Text('SERVICIOS'), numeric: true),
              DataColumn(label: Text('EFECTIVO'), numeric: true),
              DataColumn(label: Text('ACCIONES')),
            ],
            rows: [
              for (final driver in drivers)
                DataRow(
                  // Keyed by the chofer, not by where they sit: deleting one
                  // shifts every row below it up, and unkeyed rows are matched
                  // by position, so a row would be handed the next chofer's
                  // data while keeping what it had already drawn.
                  key: ValueKey(driver.id),
                  cells: [
                    DataCell(
                      Row(
                        children: [
                          DriverAvatar.of(
                            driver,
                            key: ValueKey('avatar-${driver.id}'),
                            appOpen: appOpen.contains(driver.id),
                          ),
                          const SizedBox(width: Insets.md),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(driver.name, style: text.titleSmall),
                              // Under the name rather than a column of its
                              // own, which would push the actions off-screen.
                              if (driver.email.isNotEmpty)
                                Text(
                                  driver.email,
                                  style: text.bodySmall?.copyWith(
                                    color: palette.textStrong,
                                  ),
                                ),
                              Text(
                                driver.phone,
                                style: text.bodySmall?.copyWith(
                                  color: palette.textMuted,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    DataCell(Text(driver.displayCedula)),
                    DataCell(
                      Text(
                        driver.assignedTruckId == null
                            ? 'Sin asignar'
                            : '${driver.assignedTruckPlate} · '
                                  '${driver.truckType.label}',
                      ),
                    ),
                    // Presence is the avatar's dot, with its label on hover.
                    // A chofer who registered from the app also shows where
                    // the licence check stands, until they are working.
                    DataCell(_StatusCell(driver: driver)),
                    DataCell(_RatingCell(driver: driver)),
                    DataCell(
                      Text(
                        driver.acceptanceLabel,
                        style: text.bodyMedium?.copyWith(
                          // Below 60% is either a notification problem or
                          // cherry-picking; both need looking at.
                          color: driver.acceptanceRate < 0.6
                              ? palette.danger
                              : palette.text,
                        ),
                      ),
                    ),
                    DataCell(Text('${driver.completedServices}')),
                    DataCell(
                      // The cash the chofer holds for the company, not only
                      // the commission on it: what the next corte collects.
                      Text(
                        driver.cashOnHandCents == 0
                            ? '—'
                            : driver.cashOnHandCents.formatDOP,
                        style: text.bodyMedium?.copyWith(
                          color: driver.cashOnHandCents > 0
                              ? palette.warning
                              : palette.textMuted,
                        ),
                      ),
                    ),
                    DataCell(
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            tooltip: 'Ver',
                            visualDensity: VisualDensity.compact,
                            onPressed: () => onView(driver),
                            icon: const Icon(
                              Icons.visibility_outlined,
                              size: 20,
                            ),
                          ),
                          IconButton(
                            tooltip: 'Editar',
                            visualDensity: VisualDensity.compact,
                            onPressed: () => onEdit(driver),
                            icon: const Icon(Icons.edit_outlined, size: 20),
                          ),
                          // The one status change each row most often needs:
                          // clearing a new account, or stopping a working one.
                          // Marking inactive lives in the details dialog.
                          if (driver.status.canWork)
                            IconButton(
                              tooltip: 'Suspender',
                              visualDensity: VisualDensity.compact,
                              onPressed: () => onChangeStatus(
                                driver,
                                DriverStatus.suspended,
                              ),
                              icon: Icon(
                                Icons.block,
                                size: 20,
                                color: palette.warning,
                              ),
                            )
                          else
                            IconButton(
                              tooltip: 'Activar',
                              visualDensity: VisualDensity.compact,
                              onPressed: () =>
                                  onChangeStatus(driver, DriverStatus.active),
                              icon: Icon(
                                Icons.check_circle_outline,
                                size: 20,
                                color: palette.success,
                              ),
                            ),
                          IconButton(
                            tooltip: 'Eliminar',
                            visualDensity: VisualDensity.compact,
                            onPressed: () => onDelete(driver),
                            icon: Icon(
                              Icons.delete_outline,
                              size: 20,
                              color: palette.danger,
                            ),
                          ),
                        ],
                      ),
                    ),
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
  const _StatusPill({required this.status});

  final DriverStatus status;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;

    final (label, fg, bg) = switch (status) {
      DriverStatus.active => ('Activo', palette.success, palette.successTint),
      DriverStatus.inactive => (
        'Inactivo',
        palette.textMuted,
        palette.surfaceSubtle,
      ),
      DriverStatus.suspended => (
        'Suspendido',
        palette.danger,
        palette.dangerTint,
      ),
      DriverStatus.unknown => ('—', palette.textMuted, palette.surfaceSubtle),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Insets.sm, vertical: 3),
      decoration: BoxDecoration(color: bg, borderRadius: Corners.brXs),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(color: fg),
      ),
    );
  }
}

/// The status pill, with what stands beside it: where the licence check is,
/// for a chofer who registered from the app and is not working yet, or where
/// their evaluation stands, for a working chofer whose record has slipped —
/// so nobody has to open each one to find out.
class _StatusCell extends StatelessWidget {
  const _StatusCell({required this.driver});

  final Driver driver;

  @override
  Widget build(BuildContext context) {
    final standing = DriverScorecard.of(driver).standing;
    final beside = driver.status == DriverStatus.active
        ? (standing.needsAttention ? DriverStandingChip(standing: standing) : null)
        : switch (driver.licenseVerification) {
            final verification? => Tooltip(
                message: 'Licencia',
                child: LicenseStatePill(state: verification.state),
              ),
            null => null,
          };
    if (beside == null) return _StatusPill(status: driver.status);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _StatusPill(status: driver.status),
        const SizedBox(height: Insets.xxs),
        beside,
      ],
    );
  }
}

/// What customers gave the chofer: stars, the average and how many ratings it
/// rests on — "Nuevo" before the first, rather than a score nobody gave.
class _RatingCell extends StatelessWidget {
  const _RatingCell({required this.driver});

  final Driver driver;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final palette = context.palette;
    final count = driver.ratingCount;

    if (count == 0) {
      return Text(
        'Nuevo',
        key: Key('rating-${driver.id}'),
        style: text.bodyMedium?.copyWith(color: palette.textMuted),
      );
    }
    final average = driver.averageRating;
    return Column(
      key: Key('rating-${driver.id}'),
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        RatingStars(value: average),
        const SizedBox(height: Insets.xxs),
        Text(
          '${average.toStringAsFixed(1)} · '
          '$count ${count == 1 ? 'calificación' : 'calificaciones'}',
          style: text.bodySmall?.copyWith(color: palette.textMuted),
        ),
      ],
    );
  }
}
