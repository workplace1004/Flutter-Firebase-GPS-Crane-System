import { beforeAll, beforeEach, describe, expect, it } from 'vitest';

import { useIsolatedProject } from './support/emulator.js';

/**
 * Weekly cortes against real Firestore:
 *
 *     npm run test:emulator
 *
 * What only the database can prove: that a job lands in exactly one corte,
 * that closing a corte clears the chofer's commission debt, and that
 * cancelling one gives its jobs back to the next.
 */

const describeEmulator = process.env['FIRESTORE_EMULATOR_HOST'] ? describe : describe.skip;

interface Token {
  uid: string;
  token: Record<string, unknown>;
}

const ADMIN: Token = { uid: 'admin-1', token: { role: 'admin' } };
const OPS: Token = { uid: 'ops-1', token: { role: 'ops' } };
const CARLOS: Token = { uid: 'carlos', token: { role: 'driver', driverId: 'carlos' } };

function request(data: unknown, who?: Token) {
  return {
    data,
    auth: who ? { uid: who.uid, token: { uid: who.uid, ...who.token } } : undefined,
    rawRequest: {},
    acceptsStreaming: false,
  } as never;
}

async function call<T>(fn: { run: (req: never) => T | Promise<T> }, data: unknown, who?: Token) {
  return fn.run(request(data, who)) as Promise<Awaited<T>>;
}

async function refusal(promise: Promise<unknown>): Promise<{ code: string; message: string }> {
  try {
    await promise;
  } catch (error) {
    const e = error as { code: string; message: string };
    return { code: e.code, message: e.message };
  }
  throw new Error('expected the call to be refused');
}

let fns: typeof import('../src/callables/settlements.js');
let payments: typeof import('../src/callables/payments.js');
let Paths: typeof import('../src/lib/firestore.js')['Paths'];
let db: FirebaseFirestore.Firestore;

const hoursAgo = (h: number) => new Date(Date.now() - h * 3600_000);

async function wipe(): Promise<void> {
  for (const name of ['drivers', 'earnings', 'driverSettlements', 'services', 'config', 'audit']) {
    await db.recursiveDelete(db.collection(name));
  }
}

async function driver(id: string, cashOwedCents: number): Promise<void> {
  await Paths.driver(id).set({
    name: id === 'carlos' ? 'Carlos' : `Chofer ${id}`,
    assignedTruckPlate: 'Grúa 07',
    status: 'active',
    archived: false,
    cashOwedCents,
  });
  await Paths.earnings(id).set({ driverId: id, cashOwedCents });
}

async function entry(
  driverId: string,
  serviceId: string,
  method: string,
  grossPesos: number,
  sharePesos: number,
  completedAt: Date,
): Promise<void> {
  const commission = method === 'insurer' ? grossPesos - sharePesos : sharePesos;
  await Paths.earningEntry(driverId, serviceId).set({
    serviceId,
    driverId,
    serviceCode: `GR-${serviceId}`,
    method,
    grossCents: grossPesos * 100,
    commissionCents: commission * 100,
    netCents: (grossPesos - commission) * 100,
    settled: false,
    completedAt,
  });
}

/** Carlos's week, as the office's example has it. */
async function carlosWeek(): Promise<void> {
  await driver('carlos', 180_000);
  await entry('carlos', 'ins-1', 'insurer', 3_500, 2_450, hoursAgo(90));
  await entry('carlos', 'ins-2', 'insurer', 5_500, 3_850, hoursAgo(70));
  await entry('carlos', 'ins-3', 'insurer', 2_500, 1_750, hoursAgo(50));
  await entry('carlos', 'cash-1', 'cash', 4_000, 800, hoursAgo(40));
  await entry('carlos', 'cash-2', 'cash', 5_000, 1_000, hoursAgo(20));
}

async function entryData(driverId: string, serviceId: string) {
  return (await Paths.earningEntry(driverId, serviceId).get()).data()!;
}

async function corte(id: string) {
  return (await Paths.driverSettlement(id).get()).data()!;
}

describeEmulator('weekly cortes', () => {
  beforeAll(async () => {
    useIsolatedProject('grua-settlements');
    fns = await import('../src/callables/settlements.js');
    payments = await import('../src/callables/payments.js');
    const firestore = await import('../src/lib/firestore.js');
    Paths = firestore.Paths;
    db = firestore.db;
  });

  beforeEach(wipe);

  it('makes Carlos’s corte: Drakegruas pays RD$6,250', async () => {
    await carlosWeek();
    const { created } = await call(fns.generateDriverSettlements, { driverId: 'carlos' }, ADMIN);

    expect(created).toHaveLength(1);
    expect(created[0]).toMatchObject({ driverId: 'carlos', finalBalanceCents: 625_000, direction: 'to_driver' });

    const c = await corte(created[0]!.settlementId);
    expect(c).toMatchObject({
      driverId: 'carlos',
      driverName: 'Carlos',
      truckPlate: 'Grúa 07',
      insuranceOwedCents: 805_000,
      commissionOwedCents: 180_000,
      finalBalanceCents: 625_000,
      direction: 'to_driver',
      status: 'pending',
      createdBy: 'admin-1',
    });
    expect(c['lines']).toHaveLength(5);
    expect(c['lines'].map((l: { amountCents: number }) => l.amountCents)).toEqual([
      245_000, 385_000, 175_000, 80_000, 100_000,
    ]);

    // Due Friday at 5 p.m. Dominican time (21:00Z).
    const payBy = (c['payBy'] as FirebaseFirestore.Timestamp).toDate();
    expect(payBy.getUTCDay()).toBe(5);
    expect(payBy.getUTCHours()).toBe(21);

    for (const id of ['ins-1', 'ins-2', 'ins-3', 'cash-1', 'cash-2']) {
      const e = await entryData('carlos', id);
      expect(e['settled']).toBe(true);
      expect(e['settlementId']).toBe(created[0]!.settlementId);
    }
  });

  it('never counts a job twice', async () => {
    await carlosWeek();
    await call(fns.generateDriverSettlements, { driverId: 'carlos' }, ADMIN);
    const again = await call(fns.generateDriverSettlements, { driverId: 'carlos' }, ADMIN);
    expect(again.created).toEqual([]);

    // Two runs at the same moment: one corte, not two.
    await wipe();
    await carlosWeek();
    const [a, b] = await Promise.all([
      call(fns.generateDriverSettlements, { driverId: 'carlos' }, ADMIN),
      call(fns.generateDriverSettlements, { driverId: 'carlos' }, ADMIN),
    ]);
    expect(a.created.length + b.created.length).toBe(1);
    const all = await Paths.driverSettlements().where('driverId', '==', 'carlos').get();
    expect(all.size).toBe(1);
    // Two transactions on the same documents: the emulator makes the loser wait
    // out a lock, which takes a few seconds.
  }, 30_000);

  it('leaves jobs finished after the cutoff for later, and retires card jobs', async () => {
    await carlosWeek();
    await entry('carlos', 'later', 'insurer', 2_500, 1_750, new Date(Date.now() + 3600_000));
    await entry('carlos', 'card-1', 'card', 2_500, 2_000, hoursAgo(10));

    const { created } = await call(fns.generateDriverSettlements, { driverId: 'carlos' }, ADMIN);
    const c = await corte(created[0]!.settlementId);
    expect(c['finalBalanceCents']).toBe(625_000);
    expect(c['ignoredServiceIds']).toEqual(['card-1']);
    expect((await entryData('carlos', 'later'))['settled']).toBe(false);
    // Paid by card long ago: nothing to settle, and not looked at again.
    expect(await entryData('carlos', 'card-1')).toMatchObject({
      settled: true,
      retiredReason: 'unsupported_method',
    });
    expect((await entryData('carlos', 'card-1'))['settlementId']).toBeUndefined();
  });

  it('retires a lone card job without making an empty corte', async () => {
    await driver('ana', 0);
    await entry('ana', 'card-1', 'card', 2_500, 2_000, hoursAgo(10));
    const { created } = await call(fns.generateDriverSettlements, { driverId: 'ana' }, ADMIN);
    expect(created).toEqual([]);
    expect((await entryData('ana', 'card-1'))['settled']).toBe(true);
  });

  it('reaches this week however many old entries wait before the start date', async () => {
    await carlosWeek();
    // Older than the start date and never settled: left alone, and not in the way.
    for (let i = 0; i < 30; i++) {
      await entry('carlos', `old-${i.toString().padStart(2, '0')}`, 'cash', 4_000, 800, hoursAgo(500 + i));
    }
    await Paths.settlementsConfig().set({ startAt: hoursAgo(100) });

    const { created } = await call(fns.generateDriverSettlements, { driverId: 'carlos' }, ADMIN);
    const c = await corte(created[0]!.settlementId);
    expect(c['lines']).toHaveLength(5);
    expect(c['finalBalanceCents']).toBe(625_000);
    expect((await entryData('carlos', 'old-00'))['settled']).toBe(false);
  });

  it('marks the cash jobs it charged, and cancelling unmarks them', async () => {
    await carlosWeek();
    for (const id of ['cash-1', 'cash-2']) {
      await Paths.service(id).set({ driverId: 'carlos', payment: { method: 'cash', status: 'cash_collected' } });
    }
    const { created } = await call(fns.generateDriverSettlements, { driverId: 'carlos' }, ADMIN);
    const id = created[0]!.settlementId;
    for (const s of ['cash-1', 'cash-2']) {
      expect((await Paths.service(s).get()).get('payment.weeklySettlementId')).toBe(id);
    }

    await call(fns.voidDriverSettlement, { settlementId: id, reason: 'Precio equivocado' }, ADMIN);
    for (const s of ['cash-1', 'cash-2']) {
      expect((await Paths.service(s).get()).get('payment.weeklySettlementId')).toBeUndefined();
    }
  });

  it('includes an archived chofer who is still owed', async () => {
    await driver('ex', 0);
    await Paths.driver('ex').update({ archived: true });
    await entry('ex', 'i1', 'insurer', 2_500, 1_750, hoursAgo(20));
    const { created } = await call(fns.generateDriverSettlements, {}, ADMIN);
    expect(created.map((c) => c.driverId)).toEqual(['ex']);
  });

  it('does not charge commission on cash the office already received', async () => {
    await carlosWeek();
    await Paths.service('cash-1').set({ payment: { method: 'cash', cashSettlementId: 'corte-viejo' } });

    const { created } = await call(fns.generateDriverSettlements, { driverId: 'carlos' }, ADMIN);
    const c = await corte(created[0]!.settlementId);
    expect(c['commissionOwedCents']).toBe(100_000);
    expect(c['finalBalanceCents']).toBe(705_000);
    expect(c['retiredServiceIds']).toEqual(['cash-1']);
    // Retired, so the next corte does not look at it again.
    expect((await entryData('carlos', 'cash-1'))['settlementId']).toBe(created[0]!.settlementId);
  });

  it('leaves out jobs from before cortes began', async () => {
    await carlosWeek();
    await Paths.settlementsConfig().set({ startAt: hoursAgo(45) });

    const { created } = await call(fns.generateDriverSettlements, { driverId: 'carlos' }, ADMIN);
    const c = await corte(created[0]!.settlementId);
    // Only the two cash jobs are recent enough.
    expect(c['lines']).toHaveLength(2);
    expect(c['finalBalanceCents']).toBe(-180_000);
    expect((await entryData('carlos', 'ins-1'))['settled']).toBe(false);
  });

  it('a week of cash: the chofer pays Drakegruas', async () => {
    await driver('pedro', 180_000);
    await entry('pedro', 'c1', 'cash', 4_000, 800, hoursAgo(30));
    await entry('pedro', 'c2', 'cash', 5_000, 1_000, hoursAgo(20));

    const { created } = await call(fns.generateDriverSettlements, { driverId: 'pedro' }, ADMIN);
    expect(created[0]).toMatchObject({ finalBalanceCents: -180_000, direction: 'to_company' });
    expect((await corte(created[0]!.settlementId))['status']).toBe('pending');
  });

  it('a week that nets to zero closes itself and clears the commission', async () => {
    await driver('luis', 80_000);
    await entry('luis', 'i1', 'insurer', 1_143, 800, hoursAgo(30));
    await entry('luis', 'c1', 'cash', 4_000, 800, hoursAgo(20));

    const { created } = await call(fns.generateDriverSettlements, { driverId: 'luis' }, ADMIN);
    const c = await corte(created[0]!.settlementId);
    expect(c['status']).toBe('settled');
    expect(c['settledBy']).toBe('system');
    expect((await Paths.driver('luis').get()).get('cashOwedCents')).toBe(0);
    // What the chofer's app reads, too.
    expect((await Paths.earnings('luis').get()).get('cashOwedCents')).toBe(0);
  });

  it('makes every chofer’s corte at once, skipping those with nothing', async () => {
    await carlosWeek();
    await driver('pedro', 80_000);
    await entry('pedro', 'c1', 'cash', 4_000, 800, hoursAgo(20));
    await driver('idle', 0);

    const { created } = await call(fns.generateDriverSettlements, {}, ADMIN);
    expect(created.map((c) => c.driverId).sort()).toEqual(['carlos', 'pedro']);
  });

  it('only the office admin makes, closes or cancels a corte', async () => {
    await carlosWeek();
    for (const who of [OPS, CARLOS]) {
      expect((await refusal(call(fns.generateDriverSettlements, { driverId: 'carlos' }, who))).code).toBe(
        'permission-denied',
      );
    }
    const { created } = await call(fns.generateDriverSettlements, { driverId: 'carlos' }, ADMIN);
    const id = created[0]!.settlementId;
    for (const who of [OPS, CARLOS]) {
      expect(
        (await refusal(call(fns.settleDriverSettlement, { settlementId: id, reference: 'TRF-1' }, who))).code,
      ).toBe('permission-denied');
      expect(
        (await refusal(call(fns.voidDriverSettlement, { settlementId: id, reason: 'prueba' }, who))).code,
      ).toBe('permission-denied');
    }
  });

  describe('closing a corte', () => {
    it('needs the transfer reference, then clears the commission debt', async () => {
      await carlosWeek();
      const { created } = await call(fns.generateDriverSettlements, { driverId: 'carlos' }, ADMIN);
      const id = created[0]!.settlementId;

      const missing = await refusal(call(fns.settleDriverSettlement, { settlementId: id }, ADMIN));
      expect(missing.code).toBe('invalid-argument');
      expect(missing.message).toMatch(/transferencia/);

      await call(
        fns.settleDriverSettlement,
        { settlementId: id, reference: 'BPD-778812', note: 'Pagado viernes' },
        ADMIN,
      );
      const c = await corte(id);
      expect(c).toMatchObject({ status: 'settled', reference: 'BPD-778812', settledBy: 'admin-1' });
      expect((await Paths.driver('carlos').get()).get('cashOwedCents')).toBe(0);
      expect((await Paths.earnings('carlos').get()).get('cashOwedCents')).toBe(0);
    });

    it('only once', async () => {
      await carlosWeek();
      const { created } = await call(fns.generateDriverSettlements, { driverId: 'carlos' }, ADMIN);
      const id = created[0]!.settlementId;
      await call(fns.settleDriverSettlement, { settlementId: id, reference: 'BPD-1' }, ADMIN);

      const twice = await refusal(call(fns.settleDriverSettlement, { settlementId: id, reference: 'BPD-2' }, ADMIN));
      expect(twice.code).toBe('failed-precondition');
      const voided = await refusal(call(fns.voidDriverSettlement, { settlementId: id, reason: 'error' }, ADMIN));
      expect(voided.code).toBe('failed-precondition');
    });

    it('keeps commission from jobs after the corte on the chofer’s debt', async () => {
      await carlosWeek();
      const { created } = await call(fns.generateDriverSettlements, { driverId: 'carlos' }, ADMIN);
      // A cash job finished after the corte was made adds to the debt.
      await Paths.driver('carlos').update({ cashOwedCents: 180_000 + 60_000 });

      await call(fns.settleDriverSettlement, { settlementId: created[0]!.settlementId, reference: 'BPD-1' }, ADMIN);
      expect((await Paths.driver('carlos').get()).get('cashOwedCents')).toBe(60_000);
    });
  });

  describe('the office receiving cash, and the weekly corte', () => {
    const OFFICE = OPS;

    async function cashJobs(): Promise<void> {
      await carlosWeek();
      for (const [id, cents] of [['cash-1', 400_000], ['cash-2', 500_000]] as const) {
        await Paths.service(id).set({
          driverId: 'carlos',
          payment: { method: 'cash', status: 'cash_collected', capturedCents: cents },
        });
      }
      await Paths.driver('carlos').update({ cashOnHandCents: 900_000 });
    }

    it('does not collect cash whose commission a weekly corte already charged', async () => {
      await cashJobs();
      await call(fns.generateDriverSettlements, { driverId: 'carlos' }, ADMIN);

      const refused = await refusal(call(payments.settleDriverCash, { driverId: 'carlos' }, OFFICE));
      expect(refused.code).toBe('failed-precondition');
      expect(refused.message).toMatch(/no tiene efectivo/);
    });

    it('settles the jobs it collects, so the weekly corte does not charge them again', async () => {
      await cashJobs();
      // 1,800 on these two jobs, and 600 on one after them.
      await Paths.driver('carlos').update({ cashOwedCents: 240_000 });

      const cash = await call(payments.settleDriverCash, { driverId: 'carlos' }, OFFICE);
      expect(cash).toMatchObject({ totalCents: 900_000, serviceCount: 2 });
      for (const id of ['cash-1', 'cash-2']) {
        expect(await entryData('carlos', id)).toMatchObject({
          settled: true,
          cashSettlementId: cash.settlementId,
          retiredReason: 'cash_corte',
        });
      }
      const after = (await Paths.driver('carlos').get()).data()!;
      expect(after['cashOwedCents']).toBe(60_000);
      expect(after['cashOnHandCents']).toBe(0);
      expect((await Paths.earnings('carlos').get()).get('cashOwedCents')).toBe(60_000);

      // Friday: only the insurer jobs are left to settle.
      const { created } = await call(fns.generateDriverSettlements, { driverId: 'carlos' }, ADMIN);
      const c = await corte(created[0]!.settlementId);
      expect(c['commissionOwedCents']).toBe(0);
      expect(c['finalBalanceCents']).toBe(805_000);
    });
  });

  describe('cancelling a corte', () => {
    it('gives its jobs back to the next corte', async () => {
      await carlosWeek();
      await Paths.service('cash-1').set({ payment: { method: 'cash', cashSettlementId: 'corte-viejo' } });
      const first = (await call(fns.generateDriverSettlements, { driverId: 'carlos' }, ADMIN)).created[0]!;

      const noReason = await refusal(call(fns.voidDriverSettlement, { settlementId: first.settlementId }, ADMIN));
      expect(noReason.code).toBe('invalid-argument');

      await call(fns.voidDriverSettlement, { settlementId: first.settlementId, reason: 'Precio equivocado' }, ADMIN);
      const c = await corte(first.settlementId);
      expect(c).toMatchObject({ status: 'voided', voidReason: 'Precio equivocado', voidedBy: 'admin-1' });

      for (const id of ['ins-1', 'ins-2', 'ins-3', 'cash-1', 'cash-2']) {
        const e = await entryData('carlos', id);
        expect(e['settled']).toBe(false);
        expect(e['settlementId']).toBeUndefined();
      }

      const second = (await call(fns.generateDriverSettlements, { driverId: 'carlos' }, ADMIN)).created[0]!;
      expect(second.settlementId).not.toBe(first.settlementId);
      expect(second.finalBalanceCents).toBe(first.finalBalanceCents);
    });

    it('refuses a corte that does not exist', async () => {
      const r = await refusal(call(fns.voidDriverSettlement, { settlementId: 'nope', reason: 'prueba' }, ADMIN));
      expect(r.code).toBe('not-found');
    });
  });
});
