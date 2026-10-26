import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:grua_core/grua_core.dart';

import '../shared/toast.dart';

/// Cortes semanales: every Friday, what Drakegruas pays each chofer and what each
/// chofer pays Drakegruas.
///
/// The cortes are made by the Friday run at 8:00; this screen is where the
/// office pays them, records the transfer, and cancels one that came out
/// wrong. Only an admin can do any of that — a dispatcher sees the list.
class SettlementsScreen extends ConsumerStatefulWidget {
  const SettlementsScreen({super.key});

  @override
  ConsumerState<SettlementsScreen> createState() => _SettlementsScreenState();
}

class _SettlementsScreenState extends ConsumerState<SettlementsScreen> {
  var _pendingOnly = true;
  var _generating = false;

  Future<void> _generate() async {
    setState(() => _generating = true);
    final Result<List<String>> result;
    try {
      result = await ref
          .read(functionsGatewayProvider)
          .generateDriverSettlements();
    } finally {
      // Off whatever happened: a spinner left turning after a thrown error
      // says "still working" about something that has already stopped.
      if (mounted) setState(() => _generating = false);
    }
    if (!mounted) return;
    switch (result) {
      case Ok(:final value):
        showToast(
          context,
          value.isEmpty
              ? 'No hay servicios nuevos para cortar.'
              : value.length == 1
              ? 'Se generó 1 corte.'
              : 'Se generaron ${value.length} cortes.',
          tone: value.isEmpty ? ToastTone.info : ToastTone.success,
        );
      case Err(:final failure):
        showToast(context, failure.userMessage, tone: ToastTone.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final palette = context.palette;
    final all =
        ref.watch(allDriverSettlementsProvider).value ??
        const <DriverSettlement>[];
    final isAdmin = ref.watch(currentRoleProvider).value == UserRole.admin;

    // Its own query: an old unpaid corte must never fall off the newest 200.
    final pending =
        ref.watch(pendingDriverSettlementsProvider).value ??
        const <DriverSettlement>[];
    final toPay = pending
        .where((s) => s.titanPays)
        .fold(0, (sum, s) => sum + s.amountCents);
    final toCollect = pending
        .where((s) => s.driverPays)
        .fold(0, (sum, s) => sum + s.amountCents);
    final shown = _pendingOnly ? pending : all;

    return ListView(
      padding: const EdgeInsets.all(Insets.xl),
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Cortes semanales', style: text.headlineSmall),
                  const SizedBox(height: Insets.xs),
                  Text(
                    'Los viernes a las 8:00 se hace el corte de cada chofer: lo '
                    'que Drakegruas le debe por servicios de aseguradora, menos la '
                    'comisión de sus servicios en efectivo.',
                    style: text.bodyMedium?.copyWith(color: palette.textMuted),
                  ),
                ],
              ),
            ),
            if (isAdmin)
              ElevatedButton.icon(
                key: const Key('generate-settlements'),
                onPressed: _generating ? null : _generate,
                // The theme's buttons fill their width; this one sits in a row.
                // Disabled only while it works, so it stays red: the theme's
                // disabled grey washed the label and spinner out to nothing.
                style: ElevatedButton.styleFrom(
                  minimumSize: const Size(0, 44),
                  disabledBackgroundColor: palette.brand.withValues(
                    alpha: 0.75,
                  ),
                  disabledForegroundColor: BrandColors.white,
                  disabledIconColor: BrandColors.white,
                ),
                // The spinner in place of the icon, and the label saying what
                // is happening: a greyed-out button alone reads as "not
                // allowed", not as "working on it".
                icon: _generating
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: BrandColors.white,
                        ),
                      )
                    : const Icon(Icons.playlist_add_check),
                label: Text(
                  _generating ? 'Generando cortes…' : 'Generar cortes ahora',
                ),
              ),
          ],
        ),
        const SizedBox(height: Insets.xl),
        Wrap(
          spacing: Insets.lg,
          runSpacing: Insets.lg,
          children: [
            _Kpi(
              key: const Key('kpi-to-pay'),
              label: 'Por pagar a choferes',
              value: toPay.formatDOP,
              color: palette.success,
            ),
            _Kpi(
              key: const Key('kpi-to-collect'),
              label: 'Por cobrar a choferes',
              value: toCollect.formatDOP,
              color: palette.danger,
            ),
            _Kpi(label: 'Cortes pendientes', value: '${pending.length}'),
          ],
        ),
        const SizedBox(height: Insets.xl),
        Row(
          children: [
            ChoiceChip(
              label: const Text('Pendientes'),
              selected: _pendingOnly,
              onSelected: (_) => setState(() => _pendingOnly = true),
            ),
            const SizedBox(width: Insets.sm),
            ChoiceChip(
              key: const Key('show-all-settlements'),
              label: const Text('Todos'),
              selected: !_pendingOnly,
              onSelected: (_) => setState(() => _pendingOnly = false),
            ),
          ],
        ),
        const SizedBox(height: Insets.md),
        FloatingCard(
          // While the run is going, the list is about to change under the
          // dispatcher's eyes: it says so, rather than showing a list that
          // is about to be wrong.
          child: _generating
              ? const _GeneratingNotice()
              : shown.isEmpty
              ? Text(
                  _pendingOnly
                      ? 'No hay cortes pendientes.'
                      : 'Todavía no hay cortes.',
                  style: text.bodyMedium?.copyWith(color: palette.textMuted),
                )
              : Column(
                  children: [
                    for (final s in shown)
                      _SettlementRow(settlement: s, canAct: isAdmin),
                  ],
                ),
        ),
      ],
    );
  }
}

/// Stands in for the list while the cortes are being made.
class _GeneratingNotice extends StatelessWidget {
  const _GeneratingNotice();

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final palette = context.palette;

    return Padding(
      key: const Key('settlements-generating'),
      padding: const EdgeInsets.symmetric(vertical: Insets.xxxl),
      child: Column(
        children: [
          const SizedBox.square(
            dimension: 32,
            child: CircularProgressIndicator(strokeWidth: 3),
          ),
          const SizedBox(height: Insets.lg),
          Text('Generando cortes…', style: text.titleMedium),
          const SizedBox(height: Insets.xs),
          Text(
            'Se cuenta la semana de cada chofer. Puede tardar un momento.',
            style: text.bodySmall?.copyWith(color: palette.textMuted),
          ),
        ],
      ),
    );
  }
}

class _Kpi extends StatelessWidget {
  const _Kpi({required this.label, required this.value, this.color, super.key});

  final String label;
  final String value;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return SizedBox(
      width: 260,
      child: FloatingCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            FieldLabel(label),
            const SizedBox(height: Insets.xs),
            Text(value, style: text.headlineSmall?.copyWith(color: color)),
          ],
        ),
      ),
    );
  }
}

class _SettlementRow extends StatelessWidget {
  const _SettlementRow({required this.settlement, required this.canAct});

  final DriverSettlement settlement;
  final bool canAct;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final palette = context.palette;
    final s = settlement;
    final (label, color) = switch (s.direction) {
      SettlementDirection.toDriver => ('Drakegruas paga', palette.success),
      SettlementDirection.toCompany => ('Chofer paga', palette.danger),
      _ => ('Sin saldo', palette.textMuted),
    };

    return ListTile(
      key: Key('settlement-row-${s.id}'),
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.receipt_long_outlined),
      title: Text(
        [
          if (s.driverName.isEmpty) 'Chofer' else s.driverName,
          if (s.truckPlate.isNotEmpty) s.truckPlate,
        ].join(' · '),
      ),
      subtitle: Text(
        [
          if (s.periodStart != null && s.periodEnd != null)
            '${DoTime.dayMonth(s.periodStart!)} – ${DoTime.dayMonth(s.periodEnd!)}',
          s.status.label,
          if (s.reference.isNotEmpty) 'Ref. ${s.reference}',
        ].join(' · '),
      ),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            s.amountCents.formatDOP,
            style: text.titleMedium?.copyWith(color: color),
          ),
          Text(label, style: text.bodySmall?.copyWith(color: color)),
        ],
      ),
      onTap: () => showDialog<void>(
        context: context,
        builder: (_) => _SettlementDialog(settlementId: s.id, canAct: canAct),
      ),
    );
  }
}

/// One corte, and what the office can do with it.
class _SettlementDialog extends ConsumerStatefulWidget {
  const _SettlementDialog({required this.settlementId, required this.canAct});

  final String settlementId;
  final bool canAct;

  @override
  ConsumerState<_SettlementDialog> createState() => _SettlementDialogState();
}

enum _Mode { view, pay, cancel }

class _SettlementDialogState extends ConsumerState<_SettlementDialog> {
  final _reference = TextEditingController();
  final _note = TextEditingController();
  final _reason = TextEditingController();
  _Mode _mode = _Mode.view;
  var _saving = false;
  String? _error;

  @override
  void dispose() {
    _reference.dispose();
    _note.dispose();
    _reason.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    final gateway = ref.read(functionsGatewayProvider);
    final result = _mode == _Mode.pay
        ? await gateway.settleDriverSettlement(
            settlementId: widget.settlementId,
            reference: _reference.text.trim(),
            note: _note.text.trim(),
          )
        : await gateway.voidDriverSettlement(
            settlementId: widget.settlementId,
            reason: _reason.text.trim(),
          );
    if (!mounted) return;
    switch (result) {
      case Ok():
        final toast = Toaster.of(context);
        final done = _mode == _Mode.pay
            ? 'Corte marcado como pagado.'
            : 'Corte anulado.';
        Navigator.of(context).pop();
        toast.show(done);
      case Err(:final failure):
        setState(() {
          _saving = false;
          _error = failure.userMessage;
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(driverSettlementProvider(widget.settlementId));
    final palette = context.palette;
    final corte = async.value;
    if (corte == null) {
      // Loading, or gone: either way the dialog can be closed.
      return AlertDialog(
        content: SizedBox(
          height: 120,
          child: async.isLoading
              ? const BrandLoader()
              : const Center(child: Text('No pudimos abrir este corte.')),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cerrar'),
          ),
        ],
      );
    }

    final canAct = widget.canAct && corte.isPending;
    final payLabel = switch (corte.direction) {
      SettlementDirection.toDriver => 'Registrar transferencia al chofer',
      SettlementDirection.toCompany => 'Registrar pago del chofer',
      _ => 'Cerrar corte',
    };

    return AlertDialog(
      content: SizedBox(
        width: 640,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SettlementView(settlement: corte),
              if (_mode == _Mode.pay) ...[
                const SizedBox(height: Insets.lg),
                TextField(
                  key: const Key('settlement-reference'),
                  controller: _reference,
                  decoration: const InputDecoration(
                    labelText: 'Número de transferencia o depósito',
                  ),
                ),
                const SizedBox(height: Insets.sm),
                TextField(
                  key: const Key('settlement-note'),
                  controller: _note,
                  decoration: const InputDecoration(
                    labelText: 'Nota (opcional)',
                  ),
                ),
              ],
              if (_mode == _Mode.cancel) ...[
                const SizedBox(height: Insets.lg),
                TextField(
                  key: const Key('settlement-void-reason'),
                  controller: _reason,
                  decoration: const InputDecoration(
                    labelText: 'Por qué se anula',
                    helperText: 'Los servicios vuelven al próximo corte.',
                  ),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: Insets.md),
                InlineNotice(
                  key: const Key('settlement-error'),
                  tone: NoticeTone.error,
                  icon: Icons.error_outline,
                  message: _error!,
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving
              ? null
              : () => _mode == _Mode.view
                    ? Navigator.of(context).pop()
                    : setState(() {
                        _mode = _Mode.view;
                        _error = null;
                      }),
          child: Text(_mode == _Mode.view ? 'Cerrar' : 'Volver'),
        ),
        if (canAct && _mode == _Mode.view) ...[
          TextButton(
            key: const Key('void-settlement'),
            onPressed: () => setState(() => _mode = _Mode.cancel),
            style: TextButton.styleFrom(foregroundColor: palette.danger),
            child: const Text('Anular'),
          ),
          ElevatedButton(
            key: const Key('pay-settlement'),
            onPressed: () => setState(() => _mode = _Mode.pay),
            style: ElevatedButton.styleFrom(minimumSize: const Size(0, 44)),
            child: Text(payLabel),
          ),
        ],
        if (canAct && _mode != _Mode.view)
          ElevatedButton(
            key: const Key('confirm-settlement'),
            onPressed: _saving ? null : _submit,
            style: ElevatedButton.styleFrom(
              minimumSize: const Size(0, 44),
              backgroundColor: _mode == _Mode.cancel ? palette.danger : null,
            ),
            child: Text(
              _mode == _Mode.pay ? 'Confirmar pago' : 'Confirmar anulación',
            ),
          ),
      ],
    );
  }
}
