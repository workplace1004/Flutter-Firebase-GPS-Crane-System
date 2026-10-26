import { onCall } from 'firebase-functions/v2/https';
import { onSchedule } from 'firebase-functions/v2/scheduler';
import { logger } from 'firebase-functions/v2';
import { z } from 'zod';

import { Code, invalidArgument, notFound, precondition } from '../lib/errors.js';
import { FieldValue, Paths, Timestamp, db } from '../lib/firestore.js';
import { requireAdmin } from '../lib/guards.js';
import { alertAdmins, notify } from '../lib/push.js';
import { PaymentMethod } from '../lib/enums.js';
import {
  type SettleableEntry,
  SettlementDirection,
  SettlementStatus,
  draftSettlement,
  payByFor,
} from '../lib/settlements.js';
import { audit } from './admin.js';
import { region } from './region.js';

/**
 * Weekly cortes: generated every Friday morning, paid by transfer the same day.
 *
 * Only the office can make, close or cancel one. A chofer reads their own.
 * See `lib/settlements.ts` for the arithmetic.
 */

const pesos = (cents: number) =>
  `RD$ ${(Math.abs(cents) / 100).toLocaleString('en-US', { minimumFractionDigits: 2 })}`;

const toDate = (value: unknown): Date | null =>
  value instanceof Timestamp ? value.toDate() : value instanceof Date ? value : null;

/** The day weekly cortes began, if the office set one. */
async function settlementsStartAt(): Promise<Date | null> {
  const snap = await Paths.settlementsConfig().get();
  return toDate(snap.data()?.['startAt']);
}

export interface GeneratedSettlement {
  settlementId: string;
  driverId: string;
  finalBalanceCents: number;
  direction: SettlementDirection;
}

/**
 * Writes [driverId]'s corte for everything finished by [cutoff], or nothing.
 *
 * One transaction reads the unsettled entries, writes the corte and marks each
 * entry with its id, so an entry can never land in two cortes — two runs at
 * once serialise, and the second finds nothing left.
 */
export async function generateSettlementFor(options: {
  driverId: string;
  cutoff: Date;
  actorId: string;
}): Promise<GeneratedSettlement | null> {
  const { driverId, cutoff, actorId } = options;
  const startAt = await settlementsStartAt();
  const ref = Paths.driverSettlements().doc();

  const result = await db.runTransaction(async (tx) => {
    const driverSnap = await tx.get(Paths.driver(driverId));
    const driver = driverSnap.data();
    if (!driver) throw notFound('Chofer no encontrado.');

    // Oldest first, and only from the day cortes began: entries from before
    // it are never settled, and a query without the bound would fill its
    // page with them and never reach this week's jobs.
    let unsettled = Paths.earningEntries(driverId).where('settled', '==', false);
    if (startAt) unsettled = unsettled.where('completedAt', '>=', Timestamp.fromDate(startAt));
    const entrySnap = await tx.get(unsettled.orderBy('completedAt').limit(400));
    if (entrySnap.empty) return null;

    // A cash job the office already received at a cash corte carries that
    // corte's id on its service.
    const cashIds = entrySnap.docs
      .filter((doc) => doc.get('method') === PaymentMethod.cash)
      .map((doc) => doc.id);
    const cashServices =
      cashIds.length > 0 ? await tx.getAll(...cashIds.map((id) => Paths.service(id))) : [];
    const countedInCorte = new Set(
      cashServices.filter((s) => Boolean(s.get('payment.cashSettlementId'))).map((s) => s.id),
    );

    const entries: SettleableEntry[] = entrySnap.docs.map((doc) => ({
      serviceId: doc.id,
      serviceCode: (doc.get('serviceCode') as string | undefined) ?? '',
      method: (doc.get('method') as string | undefined) ?? '',
      grossCents: (doc.get('grossCents') as number | undefined) ?? 0,
      commissionCents: (doc.get('commissionCents') as number | undefined) ?? 0,
      netCents: (doc.get('netCents') as number | undefined) ?? 0,
      completedAt: toDate(doc.get('completedAt')),
      countedInCashCorte: countedInCorte.has(doc.id),
    }));

    const draft = draftSettlement(entries, { cutoff, startAt });
    const now = FieldValue.serverTimestamp();

    // A job paid some other way (the old card rail) has nothing to settle.
    // Retired here, with the reason, so it stops coming back every Friday.
    // With nothing to settle there is no draft, but the card jobs still need
    // retiring.
    const ignored =
      draft?.ignored ??
      entries
        .filter(
          (e) =>
            e.method !== PaymentMethod.insurer &&
            e.method !== PaymentMethod.cash &&
            e.completedAt !== null &&
            e.completedAt.getTime() <= cutoff.getTime(),
        )
        .map((e) => ({ serviceId: e.serviceId, reason: 'unsupported_method' as const }));
    for (const skip of ignored) {
      tx.update(Paths.earningEntry(driverId, skip.serviceId), {
        settled: true,
        retiredReason: skip.reason,
        settledAt: now,
      });
    }
    if (!draft || (draft.lines.length === 0 && draft.retired.length === 0)) return null;

    const nothingToPay = draft.direction === SettlementDirection.none;

    tx.create(ref, {
      driverId,
      driverName: (driver['name'] as string | undefined) ?? '',
      truckPlate: (driver['assignedTruckPlate'] as string | undefined) ?? '',
      periodStart: Timestamp.fromDate(draft.periodStart),
      periodEnd: Timestamp.fromDate(draft.periodEnd),
      lines: draft.lines.map((line) => ({
        ...line,
        completedAt: Timestamp.fromDate(line.completedAt),
      })),
      insuranceOwedCents: draft.insuranceOwedCents,
      commissionOwedCents: draft.commissionOwedCents,
      finalBalanceCents: draft.finalBalanceCents,
      direction: draft.direction,
      // A corte that nets to zero has nothing to wait for.
      status: nothingToPay ? SettlementStatus.settled : SettlementStatus.pending,
      ...(nothingToPay ? { settledAt: now, settledBy: 'system' } : {}),
      payBy: Timestamp.fromDate(payByFor(cutoff)),
      retiredServiceIds: draft.retired.map((r) => r.serviceId),
      ignoredServiceIds: draft.ignored.map((r) => r.serviceId),
      reference: '',
      note: '',
      createdBy: actorId,
      createdAt: now,
      updatedAt: now,
    });

    for (const id of [...draft.lines.map((l) => l.serviceId), ...draft.retired.map((r) => r.serviceId)]) {
      tx.update(Paths.earningEntry(driverId, id), {
        settled: true,
        settlementId: ref.id,
        settledAt: now,
      });
    }

    // The cash jobs whose commission this corte charges: marked, so the
    // office's cash corte does not collect their money a second time.
    const cashServiceIds = new Set(cashServices.filter((s) => s.exists).map((s) => s.id));
    for (const line of draft.lines) {
      if (line.kind !== 'cash' || !cashServiceIds.has(line.serviceId)) continue;
      tx.update(Paths.service(line.serviceId), { 'payment.weeklySettlementId': ref.id });
    }

    // A corte that nets to zero also clears the commission it netted.
    if (nothingToPay && draft.commissionOwedCents > 0) {
      const owed = (driver['cashOwedCents'] as number | undefined) ?? 0;
      const left = Math.max(0, owed - draft.commissionOwedCents);
      tx.update(Paths.driver(driverId), { cashOwedCents: left });
      tx.set(
        Paths.earnings(driverId),
        { cashOwedCents: left, updatedAt: now },
        { merge: true },
      );
    }

    return {
      settlementId: ref.id,
      driverId,
      finalBalanceCents: draft.finalBalanceCents,
      direction: draft.direction,
    };
  });

  if (!result) return null;

  logger.info('settlement.generated', { ...result, by: actorId });

  const body =
    result.direction === SettlementDirection.toDriver
      ? `Drakegruas te paga ${pesos(result.finalBalanceCents)} por transferencia el viernes.`
      : result.direction === SettlementDirection.toCompany
        ? `Debes pagar ${pesos(result.finalBalanceCents)} a Drakegruas por transferencia o depósito.`
        : 'Esta semana no hay saldo pendiente.';
  await notify({
    uid: driverId,
    audience: 'driver',
    title: 'Tu corte semanal está listo',
    body,
    data: { settlementId: result.settlementId, type: 'driver_settlement' },
  }).catch((error: unknown) => logger.warn('settlement.notifyFailed', { driverId, error }));

  return result;
}

/**
 * Every chofer's corte, one after another; one failure does not stop the rest.
 *
 * Archived choferes too: one who left may still be owed a week of insurer
 * jobs. Those with nothing unsettled simply get no corte.
 */
async function generateForAll(cutoff: Date, actorId: string): Promise<GeneratedSettlement[]> {
  const drivers = await Paths.drivers().get();
  const created: GeneratedSettlement[] = [];
  for (const doc of drivers.docs) {
    try {
      const result = await generateSettlementFor({ driverId: doc.id, cutoff, actorId });
      if (result) created.push(result);
    } catch (error) {
      logger.error('settlement.generateFailed', { driverId: doc.id, error });
    }
  }
  return created;
}

/**
 * Makes cortes now, for one chofer or all of them. Admin only.
 *
 * The Friday run does this on its own; this is for a chofer leaving mid-week,
 * or a run that has to be repeated after a correction.
 */
export const generateDriverSettlements = onCall({ region, cors: true }, async (request) => {
  const parsed = z
    .object({ driverId: z.string().min(1).max(128).nullish() })
    .safeParse(request.data ?? {});
  if (!parsed.success) throw invalidArgument('Datos inválidos.');

  const caller = requireAdmin(request);
  const cutoff = new Date();
  const { driverId } = parsed.data;

  const created = driverId
    ? [await generateSettlementFor({ driverId, cutoff, actorId: caller.uid })].filter(
        (r): r is GeneratedSettlement => r !== null,
      )
    : await generateForAll(cutoff, caller.uid);

  await audit(caller.uid, 'generateDriverSettlements', driverId ?? 'all', {
    count: created.length,
  });
  return { created };
});

/** Every Friday at 8:00, Dominican time, for the transfers that afternoon. */
export const weeklyDriverSettlements = onSchedule(
  { schedule: '0 8 * * 5', region, timeZone: 'America/Santo_Domingo' },
  async () => {
    const created = await generateForAll(new Date(), 'system');
    if (created.length === 0) return;

    const toPay = created
      .filter((c) => c.direction === SettlementDirection.toDriver)
      .reduce((sum, c) => sum + c.finalBalanceCents, 0);
    const toCollect = created
      .filter((c) => c.direction === SettlementDirection.toCompany)
      .reduce((sum, c) => sum - c.finalBalanceCents, 0);

    await alertAdmins(
      'Cortes semanales listos',
      `${created.length} cortes. Pagar ${pesos(toPay)} · Cobrar ${pesos(toCollect)}.`,
      { type: 'driver_settlements' },
    );
  },
);

/**
 * Closes a corte: the transfer went out, or the chofer's payment came in.
 * Admin only. A corte with money in it needs the transfer or deposit
 * reference, so the bank statement can be matched to it.
 */
export const settleDriverSettlement = onCall({ region, cors: true }, async (request) => {
  const parsed = z
    .object({
      settlementId: z.string().min(1).max(128),
      reference: z.string().trim().max(120).default(''),
      note: z.string().trim().max(300).default(''),
    })
    .safeParse(request.data);
  if (!parsed.success) throw invalidArgument('Datos inválidos.');

  const caller = requireAdmin(request);
  const { settlementId, reference, note } = parsed.data;

  const settled = await db.runTransaction(async (tx) => {
    const ref = Paths.driverSettlement(settlementId);
    const snap = await tx.get(ref);
    const corte = snap.data();
    if (!corte) throw notFound('No encontramos ese corte.');
    if (corte['status'] !== SettlementStatus.pending) {
      throw precondition(Code.invalidTransition, 'Este corte ya no está pendiente.');
    }
    if (corte['finalBalanceCents'] !== 0 && reference.length < 3) {
      throw invalidArgument('Escribe el número de la transferencia o del depósito.');
    }

    const driverId = corte['driverId'] as string;
    const commission = (corte['commissionOwedCents'] as number | undefined) ?? 0;
    const driverSnap = await tx.get(Paths.driver(driverId));
    const owed = (driverSnap.get('cashOwedCents') as number | undefined) ?? 0;

    tx.update(ref, {
      status: SettlementStatus.settled,
      reference,
      note,
      settledAt: FieldValue.serverTimestamp(),
      settledBy: caller.uid,
      updatedAt: FieldValue.serverTimestamp(),
    });
    // The commission in this corte is paid now, one way or the other: it no
    // longer counts against the chofer's cash limit.
    if (driverSnap.exists) {
      tx.update(Paths.driver(driverId), {
        cashOwedCents: Math.max(0, owed - commission),
        updatedAt: FieldValue.serverTimestamp(),
      });
    }
    tx.set(
      Paths.earnings(driverId),
      {
        cashOwedCents: Math.max(0, owed - commission),
        updatedAt: FieldValue.serverTimestamp(),
      },
      { merge: true },
    );
    return { driverId, finalBalanceCents: corte['finalBalanceCents'] as number };
  });

  await audit(caller.uid, 'settleDriverSettlement', settlementId, { reference, ...settled });
  logger.info('settlement.settled', { settlementId, by: caller.uid, ...settled });
  return { ok: true };
});

/**
 * Cancels a pending corte. Admin only.
 *
 * Its jobs go back to unsettled, so the next corte counts them again — the way
 * to correct one that was made on a wrong price.
 */
export const voidDriverSettlement = onCall({ region, cors: true }, async (request) => {
  const parsed = z
    .object({
      settlementId: z.string().min(1).max(128),
      reason: z.string().trim().min(3).max(300),
    })
    .safeParse(request.data);
  if (!parsed.success) throw invalidArgument('Escribe por qué se anula el corte.');

  const caller = requireAdmin(request);
  const { settlementId, reason } = parsed.data;

  await db.runTransaction(async (tx) => {
    const ref = Paths.driverSettlement(settlementId);
    const snap = await tx.get(ref);
    const corte = snap.data();
    if (!corte) throw notFound('No encontramos ese corte.');
    if (corte['status'] !== SettlementStatus.pending) {
      throw precondition(Code.invalidTransition, 'Solo se puede anular un corte pendiente.');
    }

    const driverId = corte['driverId'] as string;
    const ids = [
      ...((corte['lines'] as { serviceId: string }[] | undefined) ?? []).map((l) => l.serviceId),
      ...((corte['retiredServiceIds'] as string[] | undefined) ?? []),
    ];
    const entryRefs = ids.map((id) => Paths.earningEntry(driverId, id));
    const entries = entryRefs.length > 0 ? await tx.getAll(...entryRefs) : [];
    const cashLineIds = ((corte['lines'] as { serviceId: string; kind: string }[] | undefined) ?? [])
      .filter((l) => l.kind === 'cash')
      .map((l) => l.serviceId);
    const cashServices =
      cashLineIds.length > 0 ? await tx.getAll(...cashLineIds.map((id) => Paths.service(id))) : [];

    tx.update(ref, {
      status: SettlementStatus.voided,
      voidReason: reason,
      voidedAt: FieldValue.serverTimestamp(),
      voidedBy: caller.uid,
      updatedAt: FieldValue.serverTimestamp(),
    });
    for (const entry of entries) {
      // Only what this corte took: an entry since re-settled is left alone.
      if (entry.get('settlementId') !== settlementId) continue;
      tx.update(entry.ref, {
        settled: false,
        settlementId: FieldValue.delete(),
        settledAt: FieldValue.delete(),
      });
    }
    for (const service of cashServices) {
      if (service.get('payment.weeklySettlementId') !== settlementId) continue;
      tx.update(service.ref, { 'payment.weeklySettlementId': FieldValue.delete() });
    }
  });

  await audit(caller.uid, 'voidDriverSettlement', settlementId, { reason });
  logger.info('settlement.voided', { settlementId, by: caller.uid });
  return { ok: true };
});
