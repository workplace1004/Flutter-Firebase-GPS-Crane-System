import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// Riverpod 3 keeps the family types out of the default export surface.
import 'package:flutter_riverpod/misc.dart' show FutureProviderFamily;
import 'package:grua_core/grua_core.dart';

import '../evaluations/evaluation_widgets.dart';
import '../shared/toast.dart';

/// What the office does to a customer from the Clientes list: look, correct,
/// block or unblock, delete. Each is a callable; the list is live, so a
/// change shows without anything done here but saying how it went.

/// A customer's latest tows, for their details.
final FutureProviderFamily<List<Service>, String> clientRecentServicesProvider =
    FutureProvider.autoDispose.family<List<Service>, String>((ref, id) async {
  final page = await ref
      .watch(serviceRepositoryProvider)
      .fetchHistory(userId: id, role: UserRole.client, limit: 5);
  return switch (page) {
    Ok(:final value) => value.items,
    Err(:final failure) => throw failure,
  };
});

void _report(BuildContext context, Result<void> result, String done) {
  if (!context.mounted) return;
  showToast(
    context,
    result.failureOrNull?.userMessage ?? done,
    tone: result.isErr ? ToastTone.error : ToastTone.success,
  );
}

String _nameOf(AppUser client) =>
    client.hasProfile ? client.name : client.displayPhone;

/// Everything on file for one customer.
Future<void> showClientDetailsDialog(
  BuildContext context,
  WidgetRef ref,
  AppUser client,
) =>
    showDialog<void>(
      context: context,
      builder: (_) => ClientDetailsDialog(
        clientId: client.id,
        initial: client,
        onEdit: () => unawaited(showEditClientDialog(context, ref, client)),
        onBlock: () => unawaited(toggleClientBlocked(context, ref, client)),
      ),
    );

/// Corrects the customer's name, email, RNC and address.
Future<void> showEditClientDialog(
  BuildContext context,
  WidgetRef ref,
  AppUser client,
) async {
  final result = await showDialog<Result<void>>(
    context: context,
    builder: (_) => _EditClientDialog(client: client),
  );
  if (result != null && context.mounted) {
    _report(context, result, 'Datos de ${_nameOf(client)} guardados.');
  }
}

/// Blocks [client] after the office says why, or unblocks them after it
/// confirms.
Future<void> toggleClientBlocked(
  BuildContext context,
  WidgetRef ref,
  AppUser client,
) async {
  final blocking = !client.blocked;
  final reason = await showDialog<String>(
    context: context,
    builder: (_) => _BlockDialog(client: client, blocking: blocking),
  );
  if (reason == null || !context.mounted) return;
  final result = await ref.read(functionsGatewayProvider).setClientBlocked(
        clientId: client.id,
        blocked: blocking,
        reason: reason,
      );
  if (!context.mounted) return;
  _report(
    context,
    result,
    blocking
        ? '${_nameOf(client)} fue bloqueado.'
        : '${_nameOf(client)} puede volver a pedir grúas.',
  );
}

/// Deletes [client] for good after the office confirms.
Future<void> deleteClientAccount(
  BuildContext context,
  WidgetRef ref,
  AppUser client,
) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('¿Eliminar a ${_nameOf(client)}?'),
      content: const Text(
        'Se borran para siempre su cuenta, sus datos, sus vehículos y lugares '
        'guardados y las fotos de sus solicitudes. Sus servicios y facturas '
        'anteriores se conservan en el historial. Esto no se puede deshacer.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancelar'),
        ),
        TextButton(
          key: const Key('confirm-delete-client'),
          onPressed: () => Navigator.of(context).pop(true),
          style: TextButton.styleFrom(foregroundColor: context.palette.danger),
          child: const Text('Eliminar'),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return;
  final result =
      await ref.read(functionsGatewayProvider).deleteClient(client.id);
  if (!context.mounted) return;
  _report(context, result, '${_nameOf(client)} fue eliminado.');
}

class ClientDetailsDialog extends ConsumerWidget {
  const ClientDetailsDialog({
    required this.clientId,
    required this.initial,
    required this.onEdit,
    required this.onBlock,
    super.key,
  });

  final String clientId;

  /// Shown until the live record arrives.
  final AppUser initial;
  final VoidCallback onEdit;
  final VoidCallback onBlock;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    final palette = context.palette;
    final live = ref.watch(allClientsProvider).value;
    final c = live?.where((u) => u.id == clientId).firstOrNull ?? initial;
    final recent = ref.watch(clientRecentServicesProvider(clientId));

    String orDash(String value) => value.trim().isEmpty ? '—' : value;

    final tags = [
      for (final MapEntry(:key, :value) in c.ratingTags.entries)
        if (ClientRatingTag.fromWire(key) case final tag
            when tag != ClientRatingTag.unknown && value > 0)
          (tag, value),
    ]..sort((a, b) => b.$2.compareTo(a.$2));

    return Dialog(
      key: const Key('client-details'),
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
                  CircleAvatar(
                    radius: 30,
                    backgroundColor: palette.brandTint,
                    child: Text(
                      _nameOf(c).isEmpty ? '?' : _nameOf(c)[0],
                      style: text.titleLarge?.copyWith(color: palette.brand),
                    ),
                  ),
                  const SizedBox(width: Insets.lg),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(_nameOf(c), style: text.titleLarge),
                        Text(
                          c.blocked ? 'Bloqueado' : 'Activo',
                          style: text.bodySmall?.copyWith(
                            color: c.blocked ? palette.danger : palette.textMuted,
                          ),
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
                    if (c.blocked)
                      Padding(
                        padding: const EdgeInsets.only(bottom: Insets.lg),
                        child: InlineNotice(
                          tone: NoticeTone.error,
                          message: c.blockedReason.isEmpty
                              ? 'Bloqueado: no puede pedir grúas.'
                              : 'Bloqueado: ${c.blockedReason}',
                        ),
                      ),
                    _Section('Contacto', [
                      ('Teléfono', orDash(c.displayPhone)),
                      ('Correo', orDash(c.email)),
                      ('Dirección', orDash(c.address)),
                    ]),
                    _Section('Facturación', [
                      ('RNC', orDash(c.rnc)),
                      ('Forma de pago', c.preferredPaymentMethod.label),
                    ]),
                    _Section('Actividad', [
                      ('Servicios', '${c.completedServices}'),
                      (
                        'Registrado',
                        c.createdAt == null ? '—' : DoTime.fullDate(c.createdAt!),
                      ),
                    ]),
                    const _Title('Calificación de los choferes'),
                    Padding(
                      key: const Key('client-details-rating'),
                      padding: const EdgeInsets.only(
                        top: Insets.sm,
                        bottom: Insets.lg,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              RatingStars(value: c.averageRating, size: 20),
                              const SizedBox(width: Insets.sm),
                              Text(
                                c.ratingCount == 0
                                    ? 'Sin calificaciones todavía'
                                    : '${c.averageRating.toStringAsFixed(1)} · '
                                        '${c.ratingCount} '
                                        '${c.ratingCount == 1 ? 'calificación' : 'calificaciones'}',
                                style: text.bodyMedium,
                              ),
                            ],
                          ),
                          if (tags.isNotEmpty) ...[
                            const SizedBox(height: Insets.sm),
                            Wrap(
                              spacing: Insets.xs,
                              runSpacing: Insets.xs,
                              children: [
                                for (final (tag, count) in tags)
                                  RatingTagChip(tag: tag, count: count),
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),
                    const _Title('Últimos servicios'),
                    const SizedBox(height: Insets.xs),
                    switch (recent) {
                      AsyncValue(:final value?) when value.isEmpty => Text(
                          'Sin servicios todavía.',
                          style: text.bodySmall
                              ?.copyWith(color: palette.textMuted),
                        ),
                      AsyncValue(:final value?) => Column(
                          children: [
                            for (final s in value)
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: Insets.xxs,
                                ),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        [
                                          s.code,
                                          if (s.createdAt case final at?)
                                            DoTime.fullDate(at),
                                        ].join(' · '),
                                        style: text.bodyMedium,
                                      ),
                                    ),
                                    Text(
                                      s.status.officeLabel,
                                      style: text.bodySmall?.copyWith(
                                        color: palette.textMuted,
                                      ),
                                    ),
                                    const SizedBox(width: Insets.md),
                                    Text(
                                      s.totalCents.formatDOP,
                                      style: text.bodyMedium,
                                    ),
                                  ],
                                ),
                              ),
                          ],
                        ),
                      AsyncValue(:final error?) => Text(
                          switch (error) {
                            final Failure f => f.userMessage,
                            _ => 'No se pudieron cargar sus servicios.',
                          },
                          style: text.bodySmall?.copyWith(color: palette.danger),
                        ),
                      _ => const LinearProgressIndicator(minHeight: 2),
                    },
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
              child: Wrap(
                alignment: WrapAlignment.end,
                spacing: Insets.sm,
                runSpacing: Insets.sm,
                children: [
                  OutlinedButton.icon(
                    onPressed: () {
                      Navigator.of(context).pop();
                      onEdit();
                    },
                    icon: const Icon(Icons.edit_outlined, size: 18),
                    label: const Text('Editar'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () {
                      Navigator.of(context).pop();
                      onBlock();
                    },
                    style: OutlinedButton.styleFrom(
                      foregroundColor:
                          c.blocked ? palette.success : palette.warning,
                    ),
                    icon: Icon(
                      c.blocked ? Icons.check_circle_outline : Icons.block,
                      size: 18,
                    ),
                    label: Text(c.blocked ? 'Desbloquear' : 'Bloquear'),
                  ),
                  ElevatedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cerrar'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Title extends StatelessWidget {
  const _Title(this.title);

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
          _Title(title),
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
                      style: text.bodyMedium?.copyWith(color: palette.textMuted),
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

/// Name, email, RNC and address. Returns the server's answer, or null when
/// cancelled. The phone is shown, not edited: it is how they sign in.
class _EditClientDialog extends ConsumerStatefulWidget {
  const _EditClientDialog({required this.client});

  final AppUser client;

  @override
  ConsumerState<_EditClientDialog> createState() => _EditClientDialogState();
}

class _EditClientDialogState extends ConsumerState<_EditClientDialog> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.client.name);
  late final _email = TextEditingController(text: widget.client.email);
  late final _rnc = TextEditingController(text: widget.client.rnc);
  late final _address = TextEditingController(text: widget.client.address);
  var _saving = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _rnc.dispose();
    _address.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!(_form.currentState?.validate() ?? false)) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    final result = await ref.read(functionsGatewayProvider).updateClient(
          clientId: widget.client.id,
          name: _name.text.trim(),
          email: _email.text.trim(),
          rnc: _rnc.text.trim(),
          address: _address.text.trim(),
        );
    if (!mounted) return;
    if (result case Err(:final failure)) {
      setState(() {
        _saving = false;
        _error = failure.userMessage;
      });
      return;
    }
    Navigator.of(context).pop(result);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Editar cliente'),
      content: SizedBox(
        width: 440,
        child: Form(
          key: _form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextFormField(
                initialValue: widget.client.displayPhone,
                enabled: false,
                decoration: const InputDecoration(
                  labelText: 'Teléfono',
                  helperText: 'Es con lo que inicia sesión; no se cambia aquí.',
                ),
              ),
              const SizedBox(height: Insets.md),
              TextFormField(
                key: const Key('client-name'),
                controller: _name,
                decoration: const InputDecoration(labelText: 'Nombre'),
                validator: (v) => (v ?? '').trim().length < 2
                    ? 'Escribe el nombre del cliente.'
                    : null,
              ),
              const SizedBox(height: Insets.md),
              TextFormField(
                key: const Key('client-email'),
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(labelText: 'Correo'),
                validator: (v) {
                  final value = (v ?? '').trim();
                  return value.isEmpty ||
                          RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(value)
                      ? null
                      : 'Ese correo no es válido.';
                },
              ),
              const SizedBox(height: Insets.md),
              TextFormField(
                key: const Key('client-rnc'),
                controller: _rnc,
                decoration: const InputDecoration(
                  labelText: 'RNC (opcional)',
                  helperText: 'Para factura de crédito fiscal.',
                ),
                validator: (v) {
                  final digits = (v ?? '').replaceAll(RegExp(r'\D'), '');
                  return digits.isEmpty ||
                          digits.length == 9 ||
                          digits.length == 11
                      ? null
                      : 'El RNC tiene 9 dígitos, o 11 si es una cédula.';
                },
              ),
              const SizedBox(height: Insets.md),
              TextFormField(
                key: const Key('client-address'),
                controller: _address,
                decoration: const InputDecoration(labelText: 'Dirección'),
              ),
              if (_error case final error?) ...[
                const SizedBox(height: Insets.md),
                InlineNotice(message: error, tone: NoticeTone.error),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
        ElevatedButton(
          key: const Key('client-save'),
          onPressed: _saving ? null : _save,
          child: const Text('Guardar'),
        ),
      ],
    );
  }
}

/// Asks why a customer is being blocked, or confirms unblocking them.
/// Returns the reason (empty when unblocking), or null when cancelled.
class _BlockDialog extends StatefulWidget {
  const _BlockDialog({required this.client, required this.blocking});

  final AppUser client;
  final bool blocking;

  @override
  State<_BlockDialog> createState() => _BlockDialogState();
}

class _BlockDialogState extends State<_BlockDialog> {
  final _reason = TextEditingController();

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final name = _nameOf(widget.client);
    final ready = !widget.blocking || _reason.text.trim().length >= 3;
    return AlertDialog(
      title: Text(widget.blocking ? '¿Bloquear a $name?' : '¿Desbloquear a $name?'),
      content: SizedBox(
        width: 440,
        child: widget.blocking
            ? Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'No podrá pedir grúas hasta que lo desbloquees. Puede '
                    'seguir entrando y ver su historial.',
                  ),
                  const SizedBox(height: Insets.md),
                  TextField(
                    key: const Key('block-reason'),
                    controller: _reason,
                    autofocus: true,
                    maxLines: 2,
                    maxLength: 300,
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(
                      labelText: 'Motivo',
                      hintText: 'Ej.: No pagó dos servicios.',
                    ),
                  ),
                ],
              )
            : const Text('Podrá volver a pedir grúas desde la app.'),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
        ElevatedButton(
          key: const Key('block-confirm'),
          onPressed:
              ready ? () => Navigator.of(context).pop(_reason.text.trim()) : null,
          child: Text(widget.blocking ? 'Bloquear' : 'Desbloquear'),
        ),
      ],
    );
  }
}
