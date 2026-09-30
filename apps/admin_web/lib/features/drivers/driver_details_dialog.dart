import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:grua_core/grua_core.dart';

import '../evaluations/evaluation_widgets.dart';
import 'driver_status_dialog.dart';

/// Everything on file for one chofer, read-only.
///
/// [onEdit], when given, closes this and opens the edit form — the usual next
/// step after spotting a wrong phone number. [onChangeStatus], when given,
/// closes this and starts moving the chofer to the status picked, which is
/// the usual next step after reading their papers.
Future<void> showDriverDetailsDialog(
  BuildContext context,
  Driver driver, {
  VoidCallback? onEdit,
  ValueChanged<DriverStatus>? onChangeStatus,
}) {
  return showDialog<void>(
    context: context,
    builder: (context) => DriverDetailsDialog(
      driver: driver,
      onEdit: onEdit,
      onChangeStatus: onChangeStatus,
    ),
  );
}

class DriverDetailsDialog extends ConsumerWidget {
  const DriverDetailsDialog({
    required this.driver,
    this.onEdit,
    this.onChangeStatus,
    super.key,
  });

  final Driver driver;
  final VoidCallback? onEdit;
  final ValueChanged<DriverStatus>? onChangeStatus;

  /// Every status the office can move this chofer to from where they are.
  List<DriverStatus> get _targets => const [
        DriverStatus.inactive,
        DriverStatus.suspended,
        DriverStatus.active,
      ].where((s) => s != driver.status).toList();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    final palette = context.palette;
    final d = driver;
    // Live, so the header follows the chofer opening or closing the app while
    // the office is reading their record.
    final appOpen =
        ref.watch(connectedDriverIdsProvider).value?.contains(d.id) ?? false;

    String orDash(String value) => value.trim().isEmpty ? '—' : value;
    String date(DateTime? value) => value == null ? '—' : DoTime.fullDate(value);

    return Dialog(
      backgroundColor: palette.surface,
      shape: const RoundedRectangleBorder(borderRadius: Corners.brMd),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 560,
          maxHeight: MediaQuery.sizeOf(context).height * 0.9,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Insets.xxl,
                Insets.xl,
                Insets.lg,
                Insets.lg,
              ),
              child: Row(
                children: [
                  DriverAvatar.of(d, appOpen: appOpen, size: 72),
                  const SizedBox(width: Insets.lg),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(d.name, style: text.titleLarge),
                        const SizedBox(height: Insets.xxs),
                        Text(
                          '${_statusLabel(d.status)} · '
                          '${d.presence(appOpen: appOpen).label}',
                          style: text.bodySmall
                              ?.copyWith(color: palette.textMuted),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close, size: 20),
                    tooltip: 'Cerrar',
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: palette.border),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(
                  Insets.xxl,
                  Insets.lg,
                  Insets.xxl,
                  Insets.lg,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _Section('Identidad', [
                      ('Cédula', orDash(d.displayCedula)),
                      ('Teléfono', orDash(d.phone)),
                      ('Correo', orDash(d.email)),
                    ]),
                    _Section('Licencia', [
                      ('Número', orDash(d.licenseNumber)),
                      ('Vencimiento', date(d.licenseExpiry)),
                    ]),
                    _Section('Operación', [
                      (
                        'Grúa',
                        d.assignedTruckId == null
                            ? 'Sin asignar'
                            : '${d.assignedTruckPlate} · ${d.truckType.label}',
                      ),
                      (
                        'Zonas',
                        d.zones.isEmpty
                            ? 'Toda la cobertura'
                            : d.zones.join(', '),
                      ),
                      ('Servicios completados', '${d.completedServices}'),
                      (
                        'Efectivo pendiente',
                        d.cashOwedCents == 0 ? '—' : d.cashOwedCents.formatDOP,
                      ),
                    ]),
                    const _SectionTitle('Evaluación'),
                    Padding(
                      padding: const EdgeInsets.only(
                        top: Insets.sm,
                        bottom: Insets.lg,
                      ),
                      child: DriverScorecardView(driver: d),
                    ),
                    _Section('Facturación', [
                      ('Empresa', orDash(d.companyName)),
                      ('RNC', orDash(d.rnc)),
                    ]),
                    _Section('Cuenta', [
                      ('Creada', date(d.createdAt)),
                      ('Última conexión', date(d.lastOnlineAt)),
                      ('Motivo del estado', orDash(d.statusReason)),
                    ]),
                  ],
                ),
              ),
            ),
            Container(
              padding: const EdgeInsets.all(Insets.lg),
              decoration: BoxDecoration(
                color: palette.canvas,
                border: Border(top: BorderSide(color: palette.border)),
                borderRadius: const BorderRadius.vertical(
                  bottom: Radius.circular(Corners.md),
                ),
              ),
              // A Wrap rather than a Row: with two status changes beside Edit
              // and Close the buttons can outgrow the dialog's width.
              child: SizedBox(
                width: double.infinity,
                child: Wrap(
                  alignment: WrapAlignment.end,
                  spacing: Insets.sm,
                  runSpacing: Insets.sm,
                  children: [
                    if (onEdit != null)
                      OutlinedButton.icon(
                        onPressed: () {
                          Navigator.of(context).pop();
                          onEdit!();
                        },
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size(0, 40),
                          padding:
                              const EdgeInsets.symmetric(horizontal: Insets.lg),
                        ),
                        icon: const Icon(Icons.edit_outlined, size: 18),
                        label: const Text('Editar'),
                      ),
                    if (onChangeStatus != null)
                      for (final target in _targets)
                        _StatusButton(
                          target: target,
                          onPressed: () {
                            Navigator.of(context).pop();
                            onChangeStatus!(target);
                          },
                        ),
                    ElevatedButton(
                      onPressed: () => Navigator.of(context).pop(),
                      style: ElevatedButton.styleFrom(
                        minimumSize: const Size(0, 40),
                        padding:
                            const EdgeInsets.symmetric(horizontal: Insets.lg),
                      ),
                      child: const Text('Cerrar'),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _statusLabel(DriverStatus status) => switch (status) {
        DriverStatus.active => 'Activo',
        DriverStatus.inactive => 'Inactivo',
        DriverStatus.suspended => 'Suspendido',
        DriverStatus.unknown => '—',
      };
}

/// One status change in the footer, coloured by what it does to the chofer.
class _StatusButton extends StatelessWidget {
  const _StatusButton({required this.target, required this.onPressed});

  final DriverStatus target;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;

    final (icon, color) = switch (target) {
      DriverStatus.active => (Icons.check_circle_outline, palette.success),
      DriverStatus.suspended => (Icons.block, palette.danger),
      _ => (Icons.pause_circle_outline, palette.textStrong),
    };

    return OutlinedButton.icon(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        foregroundColor: color,
        minimumSize: const Size(0, 40),
        padding: const EdgeInsets.symmetric(horizontal: Insets.md),
      ),
      icon: Icon(icon, size: 18),
      label: Text(driverStatusAction(target)),
    );
  }
}

/// A titled group of label / value rows.
class _Section extends StatelessWidget {
  const _Section(this.title, this.rows);

  final String title;
  final List<(String, String)> rows;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final palette = context.palette;

    return Padding(
      padding: const EdgeInsets.only(bottom: Insets.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SectionTitle(title),
          const SizedBox(height: Insets.xs),
          for (final (label, value) in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: Insets.xxs),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 170,
                    child: Text(
                      label,
                      style: text.bodyMedium
                          ?.copyWith(color: palette.textMuted),
                    ),
                  ),
                  Expanded(child: Text(value, style: text.bodyMedium)),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// A section's heading: its name, then a rule to the edge.
class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.title);

  final String title;

  @override
  Widget build(BuildContext context) => Row(
        children: [
          FieldLabel(title.toUpperCase()),
          const SizedBox(width: Insets.sm),
          Expanded(child: Divider(color: context.palette.border)),
        ],
      );
}
