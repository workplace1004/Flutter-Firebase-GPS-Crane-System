import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:grua_core/grua_core.dart';

import '../../router.dart';
import '../settlements/settlements_screen.dart';

/// What the chofer earned, and what they owe.
///
/// Every figure comes from the server-maintained rollup rather than a
/// client-side sum over history: a chofer two years in would otherwise pull
/// thousands of documents to draw one card, and pay for the reads.
///
/// The cash-owed balance gets its own treatment. On a cash job the chofer holds
/// the customer's money and owes the company its commission, which is the
/// number the office actually chases at the end of a week.
class EarningsScreen extends ConsumerStatefulWidget {
  const EarningsScreen({super.key});

  @override
  ConsumerState<EarningsScreen> createState() => _EarningsScreenState();
}

enum _Period { today, week, month }

class _EarningsScreenState extends ConsumerState<EarningsScreen> {
  _Period _period = _Period.today;

  @override
  Widget build(BuildContext context) {
    final earnings = ref.watch(driverEarningsProvider);
    final uid = ref.watch(currentUserIdProvider) ?? '';
    final text = Theme.of(context).textTheme;

    // No document is not "still loading": the server only creates the rollup
    // when the chofer completes their first job, so a new chofer has none and
    // simply earned nothing yet. Treating it as loading spun forever.
    final summary = earnings.hasValue
        ? earnings.value ?? EarningsSummary(driverId: uid)
        : null;

    return Scaffold(
      backgroundColor: BrandColors.offWhite,
      appBar: AppBar(
        leading: BackButton(onPressed: () => context.pop()),
        title: const Text('Mis ganancias'),
      ),
      body: summary == null
          ? earnings.hasError
              ? EmptyState(
                  title: 'No pudimos cargar tus ganancias',
                  message: 'Revisa tu conexión e inténtalo de nuevo.',
                  icon: Icons.cloud_off_outlined,
                  actionLabel: 'Reintentar',
                  onAction: () => ref.invalidate(driverEarningsProvider),
                )
              : const BrandLoader()
          : ListView(
              padding: const EdgeInsets.all(Insets.lg),
              children: [
                SegmentedButton<_Period>(
                  segments: const [
                    ButtonSegment(value: _Period.today, label: Text('Hoy')),
                    ButtonSegment(value: _Period.week, label: Text('Semana')),
                    ButtonSegment(value: _Period.month, label: Text('Mes')),
                  ],
                  selected: {_period},
                  showSelectedIcon: false,
                  onSelectionChanged: (selection) =>
                      setState(() => _period = selection.first),
                ),
                const SizedBox(height: Insets.lg),

                DriverBalanceCard(
                  balance: ref.watch(myDriverBalanceProvider),
                  onOpen: () => context.push(Routes.settlements),
                ),
                const SizedBox(height: Insets.lg),

                _TotalCard(summary: summary, period: _period),
                const SizedBox(height: Insets.lg),

                RunningSettlementCard(
                  draft: ref.watch(myRunningSettlementProvider).value,
                ),
                const SizedBox(height: Insets.lg),

                if (summary.owesCash) ...[
                  _CashOwedCard(summary: summary),
                  const SizedBox(height: Insets.lg),
                ],

                FloatingCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Últimos 7 días', style: text.titleMedium),
                      const SizedBox(height: Insets.lg),
                      SizedBox(
                        height: 120,
                        child: _WeekChart(values: summary.last7DaysNetCents),
                      ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }
}

class _TotalCard extends StatelessWidget {
  const _TotalCard({required this.summary, required this.period});

  final EarningsSummary summary;
  final _Period period;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;

    final (net, gross, services) = switch (period) {
      _Period.today => (
          summary.todayNetCents,
          summary.todayGrossCents,
          summary.todayServices,
        ),
      _Period.week => (
          summary.weekNetCents,
          summary.weekGrossCents,
          summary.weekServices,
        ),
      _Period.month => (
          summary.monthNetCents,
          summary.monthGrossCents,
          summary.monthServices,
        ),
    };

    return FloatingCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const FieldLabel('Ganancia neta'),
          const SizedBox(height: Insets.xs),
          Text(
            net.formatDOP,
            style: text.displaySmall?.copyWith(color: BrandColors.red),
          ),
          const Divider(height: Insets.xxl),
          DetailRow(label: 'Servicios', value: '$services'),
          DetailRow(label: 'Facturado', value: gross.formatDOP),
          DetailRow(
            label: 'Comisión',
            value: '-${(gross - net).formatDOP}',
            valueColor: BrandColors.grey600,
          ),
        ],
      ),
    );
  }
}

class _CashOwedCard extends StatelessWidget {
  const _CashOwedCard({required this.summary});

  final EarningsSummary summary;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;

    return FloatingCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.payments_outlined, color: BrandColors.warning),
              const SizedBox(width: Insets.sm),
              Expanded(
                child: Text('Efectivo por entregar', style: text.titleMedium),
              ),
            ],
          ),
          const SizedBox(height: Insets.md),
          Text(
            summary.cashOwedLabel,
            style: text.headlineMedium?.copyWith(color: BrandColors.warning),
          ),
          const SizedBox(height: Insets.sm),
          Text(
            'Es la comisión de los servicios que cobraste en efectivo. Se '
            'descuenta en tu corte del viernes; si ese corte sale a favor de '
            'Drakegruas, la pagas por transferencia o depósito.',
            style: text.bodySmall?.copyWith(color: BrandColors.grey600),
          ),
        ],
      ),
    );
  }
}

/// A plain bar chart. No chart library for seven bars.
class _WeekChart extends StatelessWidget {
  const _WeekChart({required this.values});

  final List<int> values;

  static const _labels = ['L', 'M', 'M', 'J', 'V', 'S', 'D'];

  @override
  Widget build(BuildContext context) {
    if (values.isEmpty) {
      return const Center(
        child: Text('Sin datos todavía', style: TextStyle(color: BrandColors.grey600)),
      );
    }

    final max = values.reduce((a, b) => a > b ? a : b);
    final text = Theme.of(context).textTheme;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        for (var i = 0; i < values.length; i++)
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 3),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Text(
                    // Thousands of pesos: the column is ~30px wide and the
                    // label only has to convey relative height.
                    '${(values[i] / 100000).toStringAsFixed(1)}k',
                    style: text.bodySmall?.copyWith(
                      fontSize: 9,
                      color: BrandColors.grey600,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Container(
                    height: max == 0 ? 4 : (values[i] / max * 76).clamp(4, 76),
                    decoration: BoxDecoration(
                      color: i == values.length - 1
                          ? BrandColors.red
                          : BrandColors.redTintStrong,
                      borderRadius: const BorderRadius.vertical(
                        top: Radius.circular(4),
                      ),
                    ),
                  ),
                  const SizedBox(height: Insets.xs),
                  Text(
                    _labels[i % _labels.length],
                    style: text.bodySmall?.copyWith(color: BrandColors.grey600),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
