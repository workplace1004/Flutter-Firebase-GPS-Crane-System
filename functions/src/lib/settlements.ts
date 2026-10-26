import { PaymentMethod } from './enums.js';
import { fromLocal, startOfLocalDay, toLocal } from './time.js';

/**
 * The weekly corte: what the company and a chofer owe each other.
 *
 * A chofer keeps the money from a cash job and owes the company its
 * commission. On an insurer's tow nobody paid the chofer, so the company owes
 * them their share. Once a week the two are netted:
 *
 *     balance = (what Drakegruas owes for insurer jobs) − (commission owed on cash jobs)
 *
 * Positive, the company transfers the balance to the chofer on Friday.
 * Negative, the chofer transfers or deposits it to the company.
 *
 * Built from the chofer's earnings entries, each counted in exactly one corte:
 * the entries a corte takes are marked with its id in the same transaction
 * that writes it. Nothing here touches Firestore.
 */

export const SettlementStatus = {
  /** Worked out, not yet paid either way. */
  pending: 'pending',
  /** Paid: the transfer went out, or the chofer's payment came in. */
  settled: 'settled',
  /** Cancelled by the office; its jobs go back into the next corte. */
  voided: 'voided',
} as const;

export type SettlementStatus = (typeof SettlementStatus)[keyof typeof SettlementStatus];

/** Who pays whom. */
export const SettlementDirection = {
  toDriver: 'to_driver',
  toCompany: 'to_company',
  none: 'none',
} as const;

export type SettlementDirection =
  (typeof SettlementDirection)[keyof typeof SettlementDirection];

/** What a corte needs to know about one earnings entry. */
export interface SettleableEntry {
  serviceId: string;
  serviceCode: string;
  method: string;
  grossCents: number;
  commissionCents: number;
  netCents: number;
  completedAt: Date | null;
  /** The cash of this job was already handed in at an office cash corte. */
  countedInCashCorte?: boolean;
}

export interface SettlementLine {
  serviceId: string;
  serviceCode: string;
  kind: 'insurer' | 'cash';
  /** What the job was worth. */
  grossCents: number;
  /** The chofer's 70% on an insurer's job; the company's 20% on a cash job. */
  amountCents: number;
  completedAt: Date;
}

export interface SettlementSkip {
  serviceId: string;
  reason: 'cash_corte' | 'unsupported_method';
}

export interface SettlementDraft {
  periodStart: Date;
  periodEnd: Date;
  lines: SettlementLine[];
  /** Section 1: what the company owes the chofer. */
  insuranceOwedCents: number;
  /** Section 2: what the chofer owes the company. */
  commissionOwedCents: number;
  /** Section 3: positive, the company pays; negative, the chofer pays. */
  finalBalanceCents: number;
  direction: SettlementDirection;
  /** Entries that are settled by this corte without a line. */
  retired: SettlementSkip[];
  /** Entries this corte leaves alone. */
  ignored: SettlementSkip[];
}

/**
 * The corte for everything [entries] holds that finished by [cutoff].
 *
 * `null` when there is nothing to settle. Entries finished before [startAt] —
 * the day weekly cortes began — are left out, so jobs from before the system
 * are not charged twice. A cash job already handed in at an old cash corte is
 * retired without a line: the office has that money, commission included.
 * Any other payment method is left untouched for a person to look at.
 */
export function draftSettlement(
  entries: readonly SettleableEntry[],
  options: { cutoff: Date; startAt?: Date | null },
): SettlementDraft | null {
  const { cutoff, startAt } = options;
  const lines: SettlementLine[] = [];
  const retired: SettlementSkip[] = [];
  const ignored: SettlementSkip[] = [];

  for (const entry of entries) {
    const at = entry.completedAt;
    if (!at || at.getTime() > cutoff.getTime()) continue;
    if (startAt && at.getTime() < startAt.getTime()) continue;

    if (entry.method === PaymentMethod.insurer) {
      lines.push({
        serviceId: entry.serviceId,
        serviceCode: entry.serviceCode,
        kind: 'insurer',
        grossCents: entry.grossCents,
        amountCents: entry.netCents,
        completedAt: at,
      });
    } else if (entry.method === PaymentMethod.cash) {
      if (entry.countedInCashCorte) {
        retired.push({ serviceId: entry.serviceId, reason: 'cash_corte' });
        continue;
      }
      lines.push({
        serviceId: entry.serviceId,
        serviceCode: entry.serviceCode,
        kind: 'cash',
        grossCents: entry.grossCents,
        amountCents: entry.commissionCents,
        completedAt: at,
      });
    } else {
      ignored.push({ serviceId: entry.serviceId, reason: 'unsupported_method' });
    }
  }

  if (lines.length === 0 && retired.length === 0) return null;

  // Ties by id, by code unit, as the app's port sorts them.
  lines.sort(
    (a, b) =>
      a.completedAt.getTime() - b.completedAt.getTime() ||
      (a.serviceId < b.serviceId ? -1 : a.serviceId > b.serviceId ? 1 : 0),
  );

  const sum = (kind: SettlementLine['kind']) =>
    lines.filter((l) => l.kind === kind).reduce((total, l) => total + l.amountCents, 0);
  const insuranceOwedCents = sum('insurer');
  const commissionOwedCents = sum('cash');
  const finalBalanceCents = insuranceOwedCents - commissionOwedCents;

  return {
    periodStart: lines[0]?.completedAt ?? cutoff,
    periodEnd: cutoff,
    lines,
    insuranceOwedCents,
    commissionOwedCents,
    finalBalanceCents,
    direction:
      finalBalanceCents > 0
        ? SettlementDirection.toDriver
        : finalBalanceCents < 0
          ? SettlementDirection.toCompany
          : SettlementDirection.none,
    retired,
    ignored,
  };
}

const DAY_MS = 24 * 60 * 60 * 1000;
const FRIDAY = 5;

/**
 * When the transfer is due: Friday at 5 p.m., Dominican time.
 *
 * The Friday of [from] if it is Friday before 5 p.m., otherwise the next one.
 */
export function payByFor(from: Date): Date {
  const localNow = toLocal(from);
  const day = localNow.getUTCDay();
  let ahead = (FRIDAY - day + 7) % 7;
  if (ahead === 0 && localNow.getUTCHours() >= 17) ahead = 7;
  const friday = new Date(startOfLocalDay(from).getTime() + ahead * DAY_MS);
  const localMidnight = toLocal(friday);
  return fromLocal(new Date(localMidnight.getTime() + 17 * 60 * 60 * 1000));
}
