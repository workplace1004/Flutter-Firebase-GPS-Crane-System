import 'package:flutter/material.dart';

import '../../domain/enums.dart';
import '../../domain/models/settlement.dart';
import '../../utils/date_time_do.dart';
import '../../utils/money.dart';
import '../brand.dart';
import '../palette.dart';
import 'brand_widgets.dart';

/// A weekly corte, laid out the way the office's printed example is: the
/// insurer jobs Drakegruas owes for, the cash jobs the chofer owes for, and the
/// balance.
///
/// Shared by the driver app and the panel, so both read the same page.
class SettlementView extends StatelessWidget {
  const SettlementView({required this.settlement, super.key});

  final DriverSettlement settlement;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final palette = context.palette;
    final s = settlement;
    final start = s.periodStart;
    final end = s.periodEnd;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          [
            'Corte semanal',
            if (s.driverName.isNotEmpty) s.driverName,
            if (s.truckPlate.isNotEmpty) '(${s.truckPlate})',
          ].join(' · '),
          style: text.titleLarge,
        ),
        if (start != null && end != null)
          Text(
            'Período: ${DoTime.fullDate(start)} – ${DoTime.fullDate(end)}',
            key: const Key('settlement-period'),
            style: text.bodyMedium?.copyWith(color: palette.textMuted),
          ),
        const SizedBox(height: Insets.lg),
        _Section(
          key: const Key('settlement-insurer'),
          title: 'Sección 1: Servicios de aseguradora',
          subtitle: 'Drakegruas le debe al conductor su parte',
          shareHeader: 'A pagar al conductor',
          lines: s.insurerLines,
          totalLabel: 'Total a pagar por Drakegruas al conductor',
          totalCents: s.insuranceOwedCents,
          color: palette.success,
          icon: Icons.shield_outlined,
        ),
        const SizedBox(height: Insets.md),
        _Section(
          key: const Key('settlement-cash'),
          title: 'Sección 2: Servicios en efectivo',
          subtitle: 'El conductor le debe a Drakegruas la comisión',
          shareHeader: 'Comisión a Drakegruas',
          lines: s.cashLines,
          totalLabel: 'Total a pagar por el conductor a Drakegruas',
          totalCents: s.commissionOwedCents,
          color: palette.warning,
          icon: Icons.payments_outlined,
        ),
        const SizedBox(height: Insets.md),
        FloatingCard(
          key: const Key('settlement-final'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Sección 3: Cálculo final', style: text.titleMedium),
              const SizedBox(height: Insets.sm),
              _AmountRow(
                label: 'Drakegruas debe al conductor',
                value: s.insuranceOwedCents.formatDOP,
              ),
              _AmountRow(
                label: 'Menos: el conductor debe a Drakegruas',
                value: '(${s.commissionOwedCents.formatDOP})',
                color: palette.danger,
              ),
              const SizedBox(height: Insets.md),
              _BalanceBanner(settlement: s),
            ],
          ),
        ),
        const SizedBox(height: Insets.md),
        _StatusLine(settlement: s),
      ],
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({
    required this.title,
    required this.subtitle,
    required this.shareHeader,
    required this.lines,
    required this.totalLabel,
    required this.totalCents,
    required this.color,
    required this.icon,
    super.key,
  });

  final String title;
  final String subtitle;
  final String shareHeader;
  final List<SettlementLine> lines;
  final String totalLabel;
  final int totalCents;
  final Color color;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final muted = text.bodySmall?.copyWith(color: context.palette.textMuted);

    return FloatingCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(icon, color: color),
              const SizedBox(width: Insets.sm),
              Expanded(child: Text(title, style: text.titleMedium)),
            ],
          ),
          Text(subtitle, style: muted),
          const SizedBox(height: Insets.md),
          if (lines.isEmpty)
            Text('Sin servicios en este período.', style: muted)
          else ...[
            Row(
              children: [
                Expanded(child: Text('Servicio', style: muted)),
                SizedBox(
                  width: 110,
                  child: Text('Monto', style: muted, textAlign: TextAlign.end),
                ),
                SizedBox(
                  width: 120,
                  child: Text(shareHeader, style: muted, textAlign: TextAlign.end),
                ),
              ],
            ),
            const Divider(),
            for (final (index, line) in lines.indexed)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: Insets.xs),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${index + 1}. ${line.serviceCode.isEmpty ? 'Servicio' : line.serviceCode}',
                            style: text.bodyMedium,
                          ),
                          if (line.completedAt != null)
                            Text(DoTime.dateAndTime(line.completedAt!), style: muted),
                        ],
                      ),
                    ),
                    SizedBox(
                      width: 110,
                      child: Text(
                        line.grossCents.formatDOP,
                        style: text.bodyMedium,
                        textAlign: TextAlign.end,
                      ),
                    ),
                    SizedBox(
                      width: 120,
                      child: Text(
                        line.amountCents.formatDOP,
                        style: text.bodyMedium?.copyWith(
                          color: color,
                          fontWeight: FontWeight.w600,
                        ),
                        textAlign: TextAlign.end,
                      ),
                    ),
                  ],
                ),
              ),
          ],
          const Divider(),
          Row(
            children: [
              Expanded(child: Text(totalLabel, style: text.titleSmall)),
              Text(
                totalCents.formatDOP,
                style: text.titleMedium?.copyWith(color: color),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _AmountRow extends StatelessWidget {
  const _AmountRow({required this.label, required this.value, this.color});

  final String label;
  final String value;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Insets.xs),
      child: Row(
        children: [
          Expanded(child: Text(label, style: text.bodyMedium)),
          Text(value, style: text.titleSmall?.copyWith(color: color)),
        ],
      ),
    );
  }
}

class _BalanceBanner extends StatelessWidget {
  const _BalanceBanner({required this.settlement});

  final DriverSettlement settlement;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final palette = context.palette;
    final s = settlement;
    final (accent, tint, detail) = switch (s.direction) {
      SettlementDirection.toDriver => (
          palette.success,
          palette.successTint,
          'Drakegruas paga al conductor ${s.amountCents.formatDOP} por transferencia bancaria'
              '${s.payBy == null ? '' : ' el ${DoTime.fullDate(s.payBy!)}'}.',
        ),
      SettlementDirection.toCompany => (
          palette.danger,
          palette.dangerTint,
          'El conductor paga a Drakegruas ${s.amountCents.formatDOP} por transferencia o depósito'
              '${s.payBy == null ? '' : ' antes del ${DoTime.fullDate(s.payBy!)}'}.',
        ),
      _ => (
          palette.textMuted,
          palette.surfaceSubtle,
          'Esta semana no hay dinero que mover.',
        ),
    };

    // The status colours are light in the dark skin, so there the banner is
    // the wash with coloured text rather than white on a solid fill.
    final dark = palette.isDark;

    return Container(
      key: const Key('settlement-balance'),
      padding: const EdgeInsets.all(Insets.md),
      decoration: BoxDecoration(
        color: dark ? tint : accent,
        borderRadius: Corners.brLg,
        border: dark ? Border.all(color: accent.withValues(alpha: 0.4)) : null,
      ),
      child: Column(
        children: [
          Text(
            s.balanceHeadline.toUpperCase(),
            textAlign: TextAlign.center,
            style: text.titleMedium
                ?.copyWith(color: dark ? accent : BrandColors.white),
          ),
          const SizedBox(height: Insets.xs),
          Text(
            detail,
            textAlign: TextAlign.center,
            style: text.bodySmall
                ?.copyWith(color: dark ? palette.text : BrandColors.white),
          ),
        ],
      ),
    );
  }
}

class _StatusLine extends StatelessWidget {
  const _StatusLine({required this.settlement});

  final DriverSettlement settlement;

  @override
  Widget build(BuildContext context) {
    final s = settlement;
    final (tone, message) = switch (s.status) {
      SettlementStatus.pending => (
          NoticeTone.warning,
          'Estado: ${s.status.label}.',
        ),
      SettlementStatus.settled => (
          NoticeTone.success,
          [
            'Estado: ${s.status.label}',
            if (s.settledAt != null) DoTime.dateAndTime(s.settledAt!),
            if (s.reference.isNotEmpty) 'Referencia ${s.reference}',
          ].join(' · '),
        ),
      SettlementStatus.voided => (
          NoticeTone.error,
          'Estado: ${s.status.label}'
              '${s.voidReason.isEmpty ? '' : ' · ${s.voidReason}'}',
        ),
      SettlementStatus.unknown => (NoticeTone.info, 'Estado desconocido.'),
    };

    return InlineNotice(
      key: const Key('settlement-status'),
      tone: tone,
      icon: Icons.info_outline,
      message: message,
    );
  }
}
