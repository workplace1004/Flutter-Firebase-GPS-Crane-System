import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:grua_core/grua_core.dart';

import '../../router.dart';

/// "Mis cortes": what Drakegruas and the chofer owe each other, week by week.
///
/// On top, what Friday's corte will say so far; below, every corte the office
/// has made, newest first.
class SettlementsScreen extends ConsumerWidget {
  const SettlementsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    final cortes = ref.watch(myDriverSettlementsProvider);
    final running = ref.watch(myRunningSettlementProvider).value;

    return Scaffold(
      backgroundColor: BrandColors.offWhite,
      appBar: AppBar(
        leading: BackButton(onPressed: () => context.pop()),
        title: const Text('Mis cortes'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(Insets.lg),
        children: [
          DriverBalanceCard(balance: ref.watch(myDriverBalanceProvider)),
          const SizedBox(height: Insets.lg),
          RunningSettlementCard(draft: running),
          const SizedBox(height: Insets.xl),
          Text('Cortes anteriores', style: text.titleMedium),
          const SizedBox(height: Insets.sm),
          switch (cortes) {
            AsyncData(:final value) when value.isEmpty => Text(
                'Todavía no tienes cortes. El primero se hace el viernes.',
                style: text.bodyMedium?.copyWith(color: BrandColors.grey600),
              ),
            AsyncData(:final value) => Column(
                children: [
                  for (final corte in value) _SettlementTile(settlement: corte),
                ],
              ),
            AsyncError() => const InlineNotice(
                tone: NoticeTone.error,
                icon: Icons.error_outline,
                message: 'No pudimos cargar tus cortes.',
              ),
            _ => const BrandLoader(),
          },
        ],
      ),
    );
  }
}

/// "Mi balance": everything Drakegruas and the chofer owe each other right now —
/// the cortes not yet paid, plus this week so far.
class DriverBalanceCard extends StatelessWidget {
  const DriverBalanceCard({required this.balance, this.onOpen, super.key});

  /// Null while the cortes load.
  final DriverBalance? balance;

  /// Shown as "Ver mis cortes" when given.
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final b = balance;
    if (b == null) {
      return const FloatingCard(
        key: Key('driver-balance'),
        child: SizedBox(height: 96, child: BrandLoader()),
      );
    }

    final total = b.totalCents;
    final (color, headline, explain) = switch (b.direction) {
      SettlementDirection.toDriver => (
          BrandColors.success,
          'Drakegruas te debe ${total.formatDOP}',
          'Se te paga por transferencia el viernes.',
        ),
      SettlementDirection.toCompany => (
          BrandColors.danger,
          'Le debes a Drakegruas ${(-total).formatDOP}',
          'Págalo por transferencia o depósito, a más tardar el viernes a las 5:00 p. m.',
        ),
      _ => (
          BrandColors.grey600,
          'Estás al día con Drakegruas',
          'No hay saldo pendiente entre tú y Drakegruas.',
        ),
    };

    String signed(int cents) => cents == 0
        ? 0.formatDOP
        : cents > 0
            ? '+${cents.formatDOP}'
            : '-${(-cents).formatDOP}';

    return FloatingCard(
      key: const Key('driver-balance'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const FieldLabel('Mi balance'),
          const SizedBox(height: Insets.xs),
          Text(
            headline,
            key: const Key('driver-balance-total'),
            style: text.headlineSmall?.copyWith(color: color),
          ),
          const SizedBox(height: Insets.xs),
          Text(explain, style: text.bodySmall?.copyWith(color: BrandColors.grey600)),
          const SizedBox(height: Insets.md),
          DetailRow(
            label: b.pending.isEmpty
                ? 'Cortes pendientes de pago'
                : 'Cortes pendientes de pago (${b.pending.length})',
            value: signed(b.pendingCents),
          ),
          DetailRow(
            label: 'Esta semana hasta ahora',
            value: signed(b.runningCents),
          ),
          if (b.nextPayBy case final payBy?)
            DetailRow(
              label: 'Próximo pago',
              value: '${DoTime.fullDate(payBy)}, ${DoTime.time(payBy)}',
            ),
          if (onOpen != null)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                key: const Key('open-settlements'),
                onPressed: onOpen,
                icon: const Icon(Icons.receipt_long_outlined),
                label: const Text('Ver mis cortes'),
              ),
            ),
        ],
      ),
    );
  }
}

/// What Friday's corte will say if nothing else happens this week.
class RunningSettlementCard extends StatelessWidget {
  const RunningSettlementCard({required this.draft, super.key});

  final SettlementDraft? draft;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final d = draft;
    final balance = d?.finalBalanceCents ?? 0;
    final (color, headline) = switch (SettlementDirection.ofBalance(balance)) {
      SettlementDirection.toDriver => (
          BrandColors.success,
          'Drakegruas te debe ${balance.formatDOP}',
        ),
      SettlementDirection.toCompany => (
          BrandColors.danger,
          'Le debes a Drakegruas ${(-balance).formatDOP}',
        ),
      _ => (BrandColors.grey600, 'Sin saldo esta semana'),
    };

    return FloatingCard(
      key: const Key('running-settlement'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const FieldLabel('Corte de esta semana (hasta ahora)'),
          const SizedBox(height: Insets.xs),
          Text(headline, style: text.headlineSmall?.copyWith(color: color)),
          if (d != null) ...[
            const SizedBox(height: Insets.md),
            DetailRow(
              label: 'Aseguradoras: Drakegruas te debe',
              value: d.insuranceOwedCents.formatDOP,
            ),
            DetailRow(
              label: 'Efectivo: comisión para Drakegruas',
              value: '-${d.commissionOwedCents.formatDOP}',
              valueColor: BrandColors.grey600,
            ),
          ],
          const SizedBox(height: Insets.sm),
          Text(
            'El corte se hace cada viernes y se paga por transferencia ese '
            'mismo día.',
            style: text.bodySmall?.copyWith(color: BrandColors.grey600),
          ),
        ],
      ),
    );
  }
}

class _SettlementTile extends StatelessWidget {
  const _SettlementTile({required this.settlement});

  final DriverSettlement settlement;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final s = settlement;
    final amount = s.amountCents.formatDOP;
    final (subtitle, color) = switch (s.direction) {
      SettlementDirection.toDriver => ('Drakegruas te paga $amount', BrandColors.success),
      SettlementDirection.toCompany => ('Pagas a Drakegruas $amount', BrandColors.danger),
      _ => ('Sin saldo', BrandColors.grey600),
    };

    return Card(
      margin: const EdgeInsets.only(bottom: Insets.sm),
      child: ListTile(
        key: Key('settlement-${s.id}'),
        leading: Icon(Icons.receipt_long_outlined, color: color),
        title: Text(
          s.periodEnd == null ? 'Corte' : 'Corte del ${DoTime.fullDate(s.periodEnd!)}',
        ),
        subtitle: Text('$subtitle · ${s.status.label}'),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => context.push(Routes.settlementFor(s.id)),
        titleTextStyle: text.titleSmall,
      ),
    );
  }
}

/// One corte, laid out like the office's printed one.
class SettlementDetailScreen extends ConsumerWidget {
  const SettlementDetailScreen({required this.settlementId, super.key});

  final String settlementId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final corte = ref.watch(driverSettlementProvider(settlementId));

    return Scaffold(
      backgroundColor: BrandColors.offWhite,
      appBar: AppBar(
        leading: BackButton(onPressed: () => context.pop()),
        title: const Text('Corte semanal'),
      ),
      body: switch (corte) {
        AsyncData(:final value?) => ListView(
            padding: const EdgeInsets.all(Insets.lg),
            children: [SettlementView(settlement: value)],
          ),
        AsyncData() => const EmptyState(
            title: 'Corte no encontrado',
            message: 'Este corte ya no existe.',
            icon: Icons.receipt_long_outlined,
          ),
        AsyncError() => const EmptyState(
            title: 'No pudimos cargar el corte',
            message: 'Revisa tu conexión e intenta de nuevo.',
            icon: Icons.error_outline,
          ),
        _ => const BrandLoader(),
      },
    );
  }
}
