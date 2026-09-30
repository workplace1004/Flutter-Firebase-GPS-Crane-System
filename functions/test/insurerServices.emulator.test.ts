import { beforeAll, describe, expect, it } from 'vitest';

import { loadRtdbRulesForAdmin, useIsolatedProject } from './support/emulator.js';

/**
 * An insurer's tow from order to earnings, on the real emulators:
 *
 *     npm run test:emulator
 *
 * The company orders, dispatch offers it to the nearest chofer with their
 * share on the offer, the chofer does the job, and it closes with nothing to
 * collect — the chofer credited 70%, the company billed later, and nobody
 * outside the office able to see the split.
 */

const describeEmulator =
  process.env['FIRESTORE_EMULATOR_HOST'] && process.env['FIREBASE_DATABASE_EMULATOR_HOST']
    ? describe
    : describe.skip;

interface Token {
  uid: string;
  token: Record<string, unknown>;
}

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

async function refusal(promise: Promise<unknown>): Promise<{ code: string; message: string; details: Record<string, unknown> }> {
  try {
    await promise;
  } catch (error) {
    const e = error as { code: string; message: string; details?: Record<string, unknown> };
    return { code: e.code, message: e.message, details: e.details ?? {} };
  }
  throw new Error('expected the call to be refused');
}

const insurer = (uid: string, insurerId: string): Token => ({
  uid,
  token: { role: 'insurer', insurerId, insurerRole: 'operator' },
});
const DRIVER: Token = { uid: 'd1', token: { role: 'driver', driverId: 'd1' } };
const OPS: Token = { uid: 'ops-1', token: { role: 'ops' } };

const OPERATOR = insurer('op-flow', 'ins-flow');
const OPERATOR_65 = insurer('op-65', 'ins-65');
const OPERATOR_OTHER = insurer('op-other', 'ins-other');

// Santo Domingo: a short trip, in the 0–10 km zone.
const PICKUP = { latitude: 18.4861, longitude: -69.9312 };
const DROPOFF = { latitude: 18.47, longitude: -69.91 };
// Santiago: well past 50 km.
const FAR = { latitude: 19.4517, longitude: -70.697 };

const place = (geo: { latitude: number; longitude: number }, address: string) => ({
  geo,
  address,
});

function order(claimNumber: string, overrides: Record<string, unknown> = {}) {
  return {
    pickup: place(PICKUP, 'Av. 27 de Febrero'),
    dropoff: place(DROPOFF, 'Taller Autocentro'),
    vehicle: { type: 'sedan', plate: 'G123456', make: 'Toyota', model: 'Corolla', color: 'Azul' },
    insurance: {
      claimNumber,
      policyNumber: 'POL-5789023-DR',
      insuredName: 'Juan Carlos Pérez',
      insuredPhone: '+18095550123',
    },
    notes: 'Portón azul',
    ...overrides,
  };
}

let fns: typeof import('../src/callables/insurerServices.js');
let lifecycle: typeof import('../src/callables/lifecycle.js');
let triggers: typeof import('../src/triggers/index.js');
let takeHome: typeof import('../src/lib/takeHome.js')['takeHome'];
let pricing: typeof import('../src/lib/pricing.js');
let zones: typeof import('../src/lib/zonePricing.js');
let Paths: typeof import('../src/lib/firestore.js')['Paths'];
let db: FirebaseFirestore.Firestore;
let geohash: typeof import('../src/lib/geo.js')['geohash'];

async function wipe(): Promise<void> {
  for (const name of ['services', 'drivers', 'insurers', 'earnings', 'pricingRules', 'audit']) {
    await db.recursiveDelete(db.collection(name));
  }
  await Paths.liveRoot().remove();
}

/** The chofer online, idle and parked by the pickup, as their app reports it. */
async function driverOnline(): Promise<void> {
  const spot = { latitude: PICKUP.latitude + 0.0004, longitude: PICKUP.longitude };
  await Paths.live('d1').set({
    lat: spot.latitude,
    lng: spot.longitude,
    geohash: geohash(spot),
    isOnline: true,
    state: 'idle',
    truckType: 'gancho',
    updatedAt: Date.now(),
  });
}

async function service(id: string) {
  return (await Paths.service(id).get()).data()!;
}

describeEmulator('an insurer’s tow, end to end', () => {
  beforeAll(async () => {
    useIsolatedProject('grua-insurer-flow');
    process.env['QUOTE_SIGNING_SECRET'] ??= 'test-secret';

    fns = await import('../src/callables/insurerServices.js');
    lifecycle = await import('../src/callables/lifecycle.js');
    triggers = await import('../src/triggers/index.js');
    takeHome = (await import('../src/lib/takeHome.js')).takeHome;
    pricing = await import('../src/lib/pricing.js');
    zones = await import('../src/lib/zonePricing.js');
    geohash = (await import('../src/lib/geo.js')).geohash;
    const firestore = await import('../src/lib/firestore.js');
    Paths = firestore.Paths;
    db = firestore.db;

    await loadRtdbRulesForAdmin();
    await wipe();

    const company = (name: string, extra: Record<string, unknown> = {}) => ({
      name,
      rnc: '130000001',
      billingEmail: 'facturas@prueba.do',
      status: 'active',
      ...extra,
    });
    const member = { insurerRole: 'operator', active: true, name: 'Operadora' };

    await Paths.insurer('ins-flow').set(company('Aseguradora Flujo'));
    await Paths.insurerMember('ins-flow', 'op-flow').set(member);
    await Paths.insurer('ins-65').set(company('Aseguradora 65', { driverPayoutBps: 6500 }));
    await Paths.insurerMember('ins-65', 'op-65').set(member);
    await Paths.insurer('ins-other').set(company('Otra Aseguradora'));
    await Paths.insurerMember('ins-other', 'op-other').set(member);

    await Paths.driver('d1').set({
      name: 'Chofer Uno',
      phone: '+18095550000',
      status: 'active',
      rating: 4.8,
      assignedTruckId: 'truck-d1',
      assignedTruckPlate: 'A123456',
      truckType: 'gancho',
      cashOwedCents: 0,
    });
    await driverOnline();
  });

  let first: string;

  describe('ordering', () => {
    it('previews RD$2,500 + ITBIS = RD$2,950, with no split in sight', async () => {
      const preview = await call(
        fns.quoteInsurerService,
        { pickup: place(PICKUP, 'A'), dropoff: place(DROPOFF, 'B'), vehicleType: 'sedan' },
        OPERATOR,
      );
      expect(preview.price.subtotalCents).toBe(250_000);
      expect(preview.price.itbisCents).toBe(45_000);
      expect(preview.price.totalCents).toBe(295_000);
      expect(preview.price.zoneMinKm).toBe(0);
      expect(preview.priced.signature).toMatch(/^[0-9a-f]{64}$/);

      const shown = JSON.stringify(preview).toLowerCase();
      expect(shown).not.toContain('payout');
      expect(shown).not.toContain('platform');
    });

    it('prices a long trip on the extra-kilometre rate', async () => {
      const preview = await call(
        fns.quoteInsurerService,
        { pickup: place(PICKUP, 'A'), dropoff: place(FAR, 'Santiago'), vehicleType: 'sedan' },
        OPERATOR,
      );
      const expected = zones.quoteZonePrice({
        rules: zones.defaultRulesFor('light'),
        distanceKm: preview.priced.distanceKm,
        tariff: 'default',
      });
      expect(preview.priced.distanceKm).toBeGreaterThan(50);
      expect(preview.price.zoneMinKm).toBe(50);
      expect(preview.price.subtotalCents).toBe(expected.subtotalCents);
    });

    it('orders the previewed tow and offers it to the nearest chofer with their 70%', async () => {
      const preview = await call(
        fns.quoteInsurerService,
        { pickup: place(PICKUP, 'A'), dropoff: place(DROPOFF, 'B'), vehicleType: 'sedan' },
        OPERATOR,
      );
      const result = await call(
        fns.createInsurerService,
        order('SIN-2024-01489', { priced: preview.priced }),
        OPERATOR,
      );
      first = result.serviceId;
      expect(result.code).toMatch(/^GR-/);
      expect(result.price.totalCents).toBe(295_000);

      const s = await service(first);
      expect(s['status']).toBe('offered');
      expect(s['clientId']).toBe('');
      expect(s['clientName']).toBe('Juan Carlos Pérez');
      expect(s['clientPhone']).toBe('+18095550123');
      expect(s['insurerId']).toBe('ins-flow');
      expect(s['insurerName']).toBe('Aseguradora Flujo');
      expect(s['requestedBy']).toEqual({ uid: 'op-flow', name: 'Operadora' });
      expect(s['insurance']).toMatchObject({
        claimNumber: 'SIN-2024-01489',
        claimKey: 'SIN202401489',
        policyNumber: 'POL-5789023-DR',
      });
      expect(s['vehicle']).toMatchObject({ type: 'sedan', plate: 'G123456' });
      expect(s['payment']).toMatchObject({ method: 'insurer', status: 'none' });
      expect(s['billing']).toMatchObject({ mode: 'insurer', subtotalCents: 250_000, tariff: 'default' });
      expect(s['quote']).toMatchObject({ subtotalCents: 250_000, itbisCents: 45_000, totalCents: 295_000 });
      expect(s['driverNotes']).toBe('Portón azul');
      expect(s['operatorReview']).toBeUndefined();

      // What the insurance company can read carries no split.
      const shown = JSON.stringify(s).toLowerCase();
      expect(shown).not.toContain('payout');
      expect(shown).not.toContain('platform');

      const billing = (await Paths.serviceBilling(first).get()).data()!;
      expect(billing).toMatchObject({
        insurerId: 'ins-flow',
        subtotalCents: 250_000,
        driverPayoutBps: 7000,
        driverPayoutCents: 175_000,
        platformCents: 75_000,
      });

      const offer = (await Paths.offer(first, 'd1').get()).data()!;
      expect(offer['state']).toBe('sent');
      expect(offer['paymentMethod']).toBe('insurer');
      expect(offer['netEarningsCents']).toBe(175_000);
      expect(offer['grossCents']).toBe(250_000);

      const events = await Paths.events(first).where('event', '==', 'requestService').get();
      expect(events.docs[0]!.data()).toMatchObject({ actorId: 'op-flow', actorRole: 'insurer' });
    });

    it('refuses a second live tow for the same claim, however it is typed', async () => {
      const r = await refusal(call(fns.createInsurerService, order('sin 2024 01489'), OPERATOR));
      expect(r.code).toBe('failed-precondition');
      expect(r.message).toMatch(/siniestro/);
      expect(r.details['serviceId']).toBe(first);
    });

    it('refuses an order without a claim number', async () => {
      const r = await refusal(call(fns.createInsurerService, order('  '), OPERATOR));
      expect(r.code).toBe('invalid-argument');
      expect(r.message).toMatch(/siniestro/);
    });

    it('refuses a previewed price that was tampered with or has expired', async () => {
      const preview = await call(
        fns.quoteInsurerService,
        { pickup: place(PICKUP, 'A'), dropoff: place(DROPOFF, 'B'), vehicleType: 'sedan' },
        OPERATOR,
      );

      const shorter = { ...preview.priced, distanceKm: preview.priced.distanceKm - 1 };
      const tampered = await refusal(
        call(fns.createInsurerService, order('SIN-TAMPER', { priced: shorter }), OPERATOR),
      );
      expect(tampered.code).toBe('failed-precondition');

      // Priced for a car, ordered for a truck.
      const truck = await refusal(
        call(
          fns.createInsurerService,
          order('SIN-TRUCK', { priced: preview.priced, vehicle: { type: 'camion' } }),
          OPERATOR,
        ),
      );
      expect(truck.code).toBe('failed-precondition');

      const expired = await refusal(
        call(
          fns.createInsurerService,
          order('SIN-OLD', { priced: { ...preview.priced, expiresAtMs: Date.now() - 1 } }),
          OPERATOR,
        ),
      );
      expect(expired.code).toBe('failed-precondition');
      expect(expired.message).toMatch(/venció/);

      const none = await Paths.services().where('insurance.claimKey', 'in', ['SINTAMPER', 'SINTRUCK', 'SINOLD']).get();
      expect(none.empty).toBe(true);
    });

    it('refuses anyone who is not an active member of a company', async () => {
      const outsider = insurer('nobody', 'ins-flow');
      expect((await refusal(call(fns.createInsurerService, order('SIN-X'), outsider))).code).toBe(
        'permission-denied',
      );
      expect((await refusal(call(fns.createInsurerService, order('SIN-X'), OPS))).code).toBe(
        'permission-denied',
      );
      expect((await refusal(call(fns.createInsurerService, order('SIN-X'), DRIVER))).code).toBe(
        'permission-denied',
      );
    });
  });

  describe('doing the job', () => {
    it('closes with nothing to collect, and credits the chofer 70%', async () => {
      await call(lifecycle.acceptService, { serviceId: first }, DRIVER);
      expect((await service(first))['status']).toBe('accepted');

      const atPickup = { latitude: PICKUP.latitude, longitude: PICKUP.longitude };
      await call(lifecycle.markArrived, { serviceId: first, position: atPickup }, DRIVER);
      await call(lifecycle.startService, { serviceId: first, photoPaths: [`service_photos/${first}/pickup_1.jpg`] }, DRIVER);

      const before = await service(first);
      const result = await call(
        lifecycle.completeService,
        { serviceId: first, position: DROPOFF, photoPaths: [`service_photos/${first}/dropoff_1.jpg`] },
        DRIVER,
      );
      expect(result).toMatchObject({ ok: true, finalCents: 295_000, billedToInsurer: true, waitingMinutes: 0 });

      const after = await service(first);
      expect(after['status']).toBe('closed');
      expect(after['payment']['status']).toBe('to_invoice');
      expect(after['final']).toEqual(after['quote']);
      expect(after['timeline']['closedAt']).toBeDefined();

      const closed = await Paths.events(first).where('event', '==', 'closeService').get();
      expect(closed.size).toBe(1);
      expect(closed.docs[0]!.data()['actorRole']).toBe('system');

      // Nothing to confirm in cash on a billed tow: it would leave the invoice.
      const cash = await refusal(
        call(lifecycle.confirmCashCollected, { serviceId: first, amountCents: 295_000 }, DRIVER),
      );
      expect(cash.code).toBe('failed-precondition');
      expect(cash.message).toMatch(/aseguradora/);
      expect((await service(first))['payment']['status']).toBe('to_invoice');

      // The earnings trigger, as Firestore would fire it on the completion.
      const completed = { ...before, ...after, status: 'completed' };
      await triggers.recordEarnings.run({
        params: { serviceId: first },
        data: {
          before: { data: () => before },
          after: { data: () => completed },
        },
      } as never);

      const entry = (await Paths.earningEntry('d1', first).get()).data()!;
      expect(entry).toMatchObject({
        grossCents: 250_000,
        netCents: 175_000,
        commissionCents: 75_000,
        method: 'insurer',
        insurerId: 'ins-flow',
        settled: false,
      });

      const summary = (await Paths.earnings('d1').get()).data()!;
      expect(summary['todayNetCents']).toBe(175_000);
      expect(summary['cashOwedCents'] ?? 0).toBe(0);

      const driver = (await Paths.driver('d1').get()).data()!;
      expect(driver['cashOwedCents']).toBe(0);
      expect(driver['currentServiceId']).toBeUndefined();
    });

    it('does not ask the chofer to confirm cash', async () => {
      const r = await refusal(
        call(lifecycle.confirmCashCollected, { serviceId: first, amountCents: 295_000 }, DRIVER),
      );
      expect(r.code).toBe('failed-precondition');
    });
  });

  describe('a company with its own rate', () => {
    let second: string;

    it('pays the chofer that company’s share', async () => {
      await driverOnline();
      second = (await call(fns.createInsurerService, order('SIN-65'), OPERATOR_65)).serviceId;

      const billing = (await Paths.serviceBilling(second).get()).data()!;
      expect(billing['driverPayoutBps']).toBe(6500);
      expect(billing['driverPayoutCents']).toBe(162_500);
      expect(billing['platformCents']).toBe(87_500);

      const offer = (await Paths.offer(second, 'd1').get()).data()!;
      expect(offer['netEarningsCents']).toBe(162_500);
    });

    it('can be cancelled by that company, and by nobody else’s', async () => {
      const other = await refusal(call(lifecycle.cancelService, { serviceId: second }, OPERATOR_OTHER));
      expect(other.code).toBe('failed-precondition');

      const wrongCompany = await refusal(call(lifecycle.cancelService, { serviceId: second }, OPERATOR));
      expect(wrongCompany.code).toBe('failed-precondition');

      await call(lifecycle.cancelService, { serviceId: second, reason: 'duplicado' }, OPERATOR_65);
      const s = await service(second);
      expect(s['status']).toBe('cancelled');
      expect(s['cancellation']).toMatchObject({ by: 'insurer', actorId: 'op-65', reason: 'duplicado' });

      const events = await Paths.events(second).where('event', '==', 'cancelService').get();
      expect(events.docs[0]!.data()['actorRole']).toBe('insurer');
    });

    it('lets the office cancel an insurer’s tow too', async () => {
      await driverOnline();
      const third = (await call(fns.createInsurerService, order('SIN-OFFICE'), OPERATOR)).serviceId;
      await call(lifecycle.cancelService, { serviceId: third }, OPS);
      expect((await service(third))['cancellation']['by']).toBe('admin');
    });

    it('frees the claim number once its tow is cancelled', async () => {
      await driverOnline();
      const again = await call(fns.createInsurerService, order('SIN-65'), OPERATOR_65);
      expect(again.serviceId).not.toBe(second);
    });
  });

  describe('heavy vehicles', () => {
    it('go straight to dispatch, for a heavy grúa, with no price to confirm', async () => {
      const { serviceId } = await call(
        fns.createInsurerService,
        order('SIN-HEAVY', { vehicle: { type: 'camion' } }),
        OPERATOR,
      );
      const s = await service(serviceId);
      expect(s['truckTypeRequired']).toBe('pesada');
      expect(s['operatorReview']).toBeUndefined();
      // Not held for an operator's price confirmation, as a customer's is.
      expect(String(s['dispatch']['lastReason'] ?? '')).not.toMatch(/confirma/i);
      expect(s['billing']['subtotalCents']).toBe(550_000);
      // The only chofer online has a hook truck: nobody is offered a job
      // their grúa cannot lift.
      expect((await Paths.offer(serviceId, 'd1').get()).exists).toBe(false);
    });
  });

  describe('a close that did not happen', () => {
    it('is finished by the sweep, and the chofer is freed', async () => {
      const scheduled = await import('../src/scheduled/index.js');
      const tenMinutesAgo = new Date(Date.now() - 10 * 60_000);
      const insurerTow = (driverId: string, completedAt: Date) => ({
        status: 'completed',
        insurerId: 'ins-flow',
        clientId: '',
        driverId,
        payment: { method: 'insurer', status: 'to_invoice' },
        timeline: { completedAt },
      });
      await Paths.driver('d-stuck').set({ name: 'Chofer', status: 'active', currentServiceId: 'stuck' });
      await Paths.service('stuck').set(insurerTow('d-stuck', tenMinutesAgo));
      // Just finished: its own close is probably still on the way.
      await Paths.service('fresh').set(insurerTow('d-fresh', new Date()));
      // A customer's job waits for the chofer to confirm the cash.
      await Paths.service('cash-job').set({
        status: 'completed',
        clientId: 'client-1',
        driverId: 'd-cash',
        payment: { method: 'cash', status: 'cash_pending' },
        timeline: { completedAt: tenMinutesAgo },
      });

      await scheduled.closeFinishedInsurerTows.run({} as never);

      expect((await service('stuck'))['status']).toBe('closed');
      expect((await service('stuck'))['payment']['status']).toBe('to_invoice');
      expect((await service('fresh'))['status']).toBe('completed');
      expect((await service('cash-job'))['status']).toBe('completed');
      expect((await Paths.driver('d-stuck').get()).get('currentServiceId')).toBeUndefined();
    });
  });

  describe('a private customer’s tow', () => {
    it('still pays the chofer 80%', async () => {
      const split = await takeHome(
        'private-1',
        { payment: { method: 'cash' }, quote: { totalCents: 400_000 } },
        pricing.DEFAULT_PRICING,
      );
      expect(split).toEqual({ grossCents: 400_000, netCents: 320_000, commissionCents: 80_000 });
    });

    it('pays on the final price, waiting included', async () => {
      const split = await takeHome(
        'private-2',
        {
          payment: { method: 'cash' },
          quote: { totalCents: 400_000 },
          final: { totalCents: 450_000 },
        },
        pricing.DEFAULT_PRICING,
      );
      expect(split.netCents).toBe(360_000);
    });
  });
});
