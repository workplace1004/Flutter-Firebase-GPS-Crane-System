import { onCall } from 'firebase-functions/v2/https';
import { z } from 'zod';

import {
  CancelledBy,
  DriverCancelReason,
  DriverLiveState,
  PaymentStatus,
  ServiceEventName,
  UserRole,
} from '../lib/enums.js';
import { Code, invalidArgument, precondition } from '../lib/errors.js';
import { FieldValue, Paths } from '../lib/firestore.js';
import { releaseIfFinished } from '../lib/driverRelease.js';
import { distanceMeters, type LatLng } from '../lib/geo.js';
import {
  requireActiveDriver,
  requireActiveInsurer,
  requireAuth,
  requireRole,
} from '../lib/guards.js';
import { isInsurerJob } from '../lib/takeHome.js';
import {
  type Quote,
  cancellationFeeCents,
  finalQuote,
  loadPricing,
} from '../lib/pricing.js';
import { notify } from '../lib/push.js';
import { applyTransition } from '../lib/stateMachine.js';
import { acceptOffer, rejectOffer } from '../dispatch/offers.js';
import { dispatchNext } from '../dispatch/dispatchNext.js';
import { loadDispatchConfig } from '../dispatch/dispatchNext.js';
import { isProofPhotoPath, MAX_PROOF_PHOTOS } from '../lib/servicePhoto.js';
import { region } from './region.js';

/**
 * The chofer's four buttons, plus cancellation.
 *
 * Each one is a server-side guard, not a UI state. "Llegué" from two kilometres
 * away is refused here — and the refusal carries the measured distance, so the
 * app can say "estás a 1.2 km del punto" instead of a flat no, which is the
 * difference between a chofer fixing the problem and a chofer calling the
 * office.
 */

const point = z.object({
  latitude: z.number().min(-90).max(90),
  longitude: z.number().min(-180).max(180),
});

const serviceOnly = z.object({ serviceId: z.string().min(1).max(64) });

/**
 * Exported so a test can check it against the payload the apps actually send.
 *
 * The apps had this as a flat `lat`/`lng` pair for `markArrived` and
 * `completeService`, which parses as "no position at all". Nothing on either
 * side of the wire could see the mismatch: both halves were valid, and only a
 * chofer standing at the customer's car found out.
 */
export const withPosition = serviceOnly.extend({ position: point });

const toLatLng = (p: z.infer<typeof point>): LatLng => ({
  latitude: p.latitude,
  longitude: p.longitude,
});

/** Reads a service, or refuses. Used by guards that need it before the txn. */
async function loadService(serviceId: string): Promise<FirebaseFirestore.DocumentData> {
  const snap = await Paths.service(serviceId).get();
  const service = snap.data();
  if (!service) throw precondition(Code.notFound, 'Este servicio ya no existe.');
  return service;
}

/** Refuses a chofer acting on somebody else's job. */
function assertAssigned(service: FirebaseFirestore.DocumentData, driverId: string): void {
  if (service['driverId'] !== driverId) {
    throw precondition(Code.invalidTransition, 'Este servicio no es tuyo.');
  }
}

// ---------------------------------------------------------------------------
// Taking work
// ---------------------------------------------------------------------------

/**
 * Online and offline for a chofer.
 *
 * No longer a switch the chofer flips: the app calls this with `online: true`
 * by itself whenever it is open and the chofer is not, and asks for offline on
 * sign-out. Closing the app is handled server-side by `followAppPresence`,
 * because a force-quit phone runs no code to call this.
 *
 * A server call because `drivers/{uid}` is server-written, and `isOnline` there
 * is what the app shows and what starts the phone publishing its position. The
 * position itself is still the phone's to write, straight to `/live/{uid}` —
 * dispatch only considers a chofer once a fresh fix lands there, so this call
 * can say "online" before the GPS has answered without offering them work.
 *
 * Going offline is refused mid-tow: the customer is watching that truck.
 * Taking a chofer offline who stopped reporting without saying so is
 * `reapStaleDrivers`' job, not the phone's.
 */
export const setOnline = onCall({ region, cors: true }, async (request) => {
  const parsed = z.object({ online: z.boolean() }).safeParse(request.data);
  if (!parsed.success) throw invalidArgument('Datos inválidos.');
  const { online } = parsed.data;

  const now = FieldValue.serverTimestamp();

  if (online) {
    const { uid, driver } = await requireActiveDriver(request);
    if (driver['archived'] === true) {
      throw precondition(Code.driverInactive, 'Tu cuenta no está activa.');
    }

    const truckId = driver['assignedTruckId'] as string | null | undefined;
    const truck = truckId ? (await Paths.truck(truckId).get()).data() : undefined;
    if (!truck || truck['archived'] === true) {
      throw precondition(
        Code.driverInactive,
        'No tienes una grúa asignada. Comunícate con la oficina.',
      );
    }

    await Paths.driver(uid).update({
      isOnline: true,
      lastOnlineAt: now,
      updatedAt: now,
    });
    return { ok: true };
  }

  // Offline is allowed for any chofer, suspended included: it only ever
  // takes them further from work.
  const caller = requireRole(request, UserRole.driver);
  const driverRef = Paths.driver(caller.uid);
  const driver = (await driverRef.get()).data();
  if (!driver) throw precondition(Code.notFound, 'Chofer no encontrado.');

  // A hold on a job that is already over must not keep them online forever.
  if (driver['currentServiceId'] && !(await releaseIfFinished(caller.uid))) {
    throw precondition(
      Code.driverBusy,
      'No puedes ponerte fuera de línea con un servicio en curso.',
      { serviceId: driver['currentServiceId'] },
    );
  }

  await driverRef.update({ isOnline: false, updatedAt: now });
  // Off the live map at once, not when the stale-position sweep gets to it.
  // Only an existing node: the admin SDK skips the rules' shape check, and a
  // node with no position is one the map and dispatch would trip over.
  const live = Paths.live(caller.uid);
  if ((await live.get()).exists()) {
    await live.update({ isOnline: false, updatedAt: Date.now() });
  }
  return { ok: true };
});

export const acceptService = onCall({ region, cors: true }, async (request) => {
  const parsed = serviceOnly.safeParse(request.data);
  if (!parsed.success) throw invalidArgument('Servicio inválido.');

  const { uid, driver } = await requireActiveDriver(request);
  await acceptOffer({ serviceId: parsed.data.serviceId, driverId: uid, driver });
  return { ok: true };
});

export const rejectService = onCall({ region, cors: true }, async (request) => {
  const parsed = serviceOnly
    .extend({ reason: z.nativeEnum(DriverCancelReason).nullish() })
    .safeParse(request.data);
  if (!parsed.success) throw invalidArgument('Servicio inválido.');

  const { uid } = await requireActiveDriver(request);
  await rejectOffer({
    serviceId: parsed.data.serviceId,
    driverId: uid,
    reason: parsed.data.reason ?? undefined,
  });
  return { ok: true };
});

// ---------------------------------------------------------------------------
// Doing the job
// ---------------------------------------------------------------------------

/**
 * "Llegué".
 *
 * The range check is the point. Without it a chofer can start the free-waiting
 * clock — and the customer's expectations — from anywhere.
 */
export const markArrived = onCall({ region, cors: true }, async (request) => {
  const parsed = withPosition.safeParse(request.data);
  if (!parsed.success) throw invalidArgument('Datos inválidos.');

  const { uid } = await requireActiveDriver(request);
  const { serviceId, position } = parsed.data;

  const service = await loadService(serviceId);
  assertAssigned(service, uid);

  const config = await loadDispatchConfig();
  const pickup = service['pickup'] as { geo: FirebaseFirestore.GeoPoint };
  const metres = Math.round(
    distanceMeters(toLatLng(position), {
      latitude: pickup.geo.latitude,
      longitude: pickup.geo.longitude,
    }),
  );

  if (metres > config.arrivalRadiusM) {
    const km = (metres / 1000).toFixed(1);
    throw precondition(
      Code.outOfRange,
      `Estás a ${km} km del punto de recogida.`,
      { distanceMeters: metres, allowedMeters: config.arrivalRadiusM },
    );
  }

  await applyTransition({
    serviceId,
    event: ServiceEventName.markArrived,
    actorId: uid,
    actorRole: UserRole.driver,
    meta: { distanceMeters: metres },
    afterCommit: async ({ service: s }) => {
      const clientId = s['clientId'] as string | undefined;
      if (!clientId) return;
      await notify({
        uid: clientId,
        audience: 'client',
        title: 'Tu grúa llegó',
        body: 'El chofer está en el punto de recogida.',
        data: { serviceId, type: 'driver_arrived' },
      });
    },
  });

  return { ok: true, distanceMeters: metres };
});

/**
 * The chofer's photos of the vehicle, at pickup and at drop-off: at least one,
 * because they are the only record of its condition when it changed hands.
 */
const proofPhotos = z.array(z.string().max(400)).min(1).max(MAX_PROOF_PHOTOS);

function assertProofPhotos(serviceId: string, paths: string[]): void {
  if (!paths.every((path) => isProofPhotoPath(serviceId, path))) {
    throw invalidArgument('Las fotos no corresponden a este servicio.');
  }
}

/**
 * "Iniciar servicio" — the vehicle is loaded.
 *
 * Photos are required because this is the moment the vehicle's condition stops
 * being the customer's word and starts being ours. The payment guard lives in
 * the transition table, since it must hold at commit time rather than when the
 * chofer tapped.
 */
export const startService = onCall({ region, cors: true }, async (request) => {
  const parsed = serviceOnly
    .extend({ photoPaths: proofPhotos })
    .safeParse(request.data);
  if (!parsed.success) throw invalidArgument('Datos inválidos.');

  const { uid } = await requireActiveDriver(request);
  const { serviceId, photoPaths } = parsed.data;
  assertProofPhotos(serviceId, photoPaths);

  const service = await loadService(serviceId);
  assertAssigned(service, uid);

  await applyTransition({
    serviceId,
    event: ServiceEventName.startService,
    actorId: uid,
    actorRole: UserRole.driver,
    meta: { photoCount: photoPaths.length },
    patch: { pickupPhotoPaths: photoPaths },
    afterCommit: async ({ service: s }) => {
      const clientId = s['clientId'] as string | undefined;
      if (!clientId) return;
      await notify({
        uid: clientId,
        audience: 'client',
        title: 'En camino al destino',
        body: 'Tu vehículo va en la grúa.',
        data: { serviceId, type: 'service_started' },
      });
    },
  });

  return { ok: true };
});

/**
 * "Finalizar servicio".
 *
 * The final price is computed here, not taken from the app: waiting time is real
 * money and only the server knows when the chofer actually arrived. Everything
 * downstream — the invoice, the ledger, the chofer's cash balance — reads
 * `final`, so this is the number that matters.
 */
export const completeService = onCall({ region, cors: true }, async (request) => {
  const parsed = withPosition
    .extend({
      photoPaths: proofPhotos,
      notes: z.string().max(500).nullish(),
    })
    .safeParse(request.data);
  if (!parsed.success) throw invalidArgument('Datos inválidos.');

  const { uid } = await requireActiveDriver(request);
  const { serviceId, position, photoPaths, notes } = parsed.data;
  assertProofPhotos(serviceId, photoPaths);

  const service = await loadService(serviceId);
  assertAssigned(service, uid);

  const config = await loadDispatchConfig();
  const dropoff = service['dropoff'] as { geo: FirebaseFirestore.GeoPoint } | undefined;

  if (dropoff) {
    const metres = Math.round(
      distanceMeters(toLatLng(position), {
        latitude: dropoff.geo.latitude,
        longitude: dropoff.geo.longitude,
      }),
    );
    if (metres > config.completionRadiusM) {
      const km = (metres / 1000).toFixed(1);
      throw precondition(
        Code.outOfRange,
        `Estás a ${km} km del destino.`,
        { distanceMeters: metres, allowedMeters: config.completionRadiusM },
      );
    }
  }

  const pricing = await loadPricing();
  const timeline = (service['timeline'] ?? {}) as Record<string, unknown>;
  const arrivedAt = (timeline['arrivedAt'] as FirebaseFirestore.Timestamp | undefined)
    ?.toDate();
  const startedAt = (timeline['startedAt'] as FirebaseFirestore.Timestamp | undefined)
    ?.toDate();

  // Only the wait between arriving and loading is billable. Time spent driving
  // to the customer is what the banderazo already covers.
  const waitingMinutes =
    arrivedAt && startedAt
      ? Math.max(0, Math.round((startedAt.getTime() - arrivedAt.getTime()) / 60000))
      : 0;

  const quote = (service['quote'] ?? {}) as Quote;
  const insurerJob = isInsurerJob(service);

  // The price the customer agreed to, plus billable waiting. Not the tariff
  // run again: that would add a night surcharge to a tow quoted at 21:50, and
  // undo the price an operator confirmed on a heavy job. An insurance
  // company's price is its contract's zone price, with no waiting charge.
  const final = insurerJob ? quote : finalQuote(quote, pricing, waitingMinutes);

  await applyTransition({
    serviceId,
    event: ServiceEventName.completeService,
    actorId: uid,
    actorRole: UserRole.driver,
    meta: { waitingMinutes, finalCents: final.totalCents },
    patch: {
      final,
      dropoffPhotoPaths: photoPaths,
      driverNotes: notes ?? service['driverNotes'] ?? '',
      // The money stays with the chofer until they confirm collection. An
      // insurer's tow has no money at the roadside: it waits for the invoice.
      'payment.status': insurerJob ? PaymentStatus.toInvoice : PaymentStatus.cashPending,
    },

    inTransaction: ({ transaction }) => {
      // Free the chofer in the same transaction as the status change, so there
      // is no window where they are neither dispatchable nor working.
      transaction.update(Paths.driver(uid), {
        currentServiceId: FieldValue.delete(),
        completedServices: FieldValue.increment(1),
        updatedAt: FieldValue.serverTimestamp(),
      });

      const clientId = service['clientId'] as string | undefined;
      if (clientId) {
        transaction.update(Paths.user(clientId), {
          activeServiceId: FieldValue.delete(),
          completedServices: FieldValue.increment(1),
          updatedAt: FieldValue.serverTimestamp(),
        });
      }
    },

    afterCommit: async ({ service: s }) => {
      await Paths.live(uid).update({
        state: DriverLiveState.idle,
        serviceId: null,
        updatedAt: Date.now(),
      });

      // Nothing to collect, so nothing for the chofer to confirm: the job is
      // done and closes here.
      if (insurerJob) {
        await applyTransition({
          serviceId,
          event: ServiceEventName.closeService,
          actorId: 'system',
          actorRole: 'system',
          meta: { reason: 'insurer_billed' },
        });
        return;
      }

      const clientId = s['clientId'] as string | undefined;
      if (clientId) {
        await notify({
          uid: clientId,
          audience: 'client',
          title: 'Servicio completado',
          body: `Total a pagar en efectivo: RD$ ${(final.totalCents / 100).toFixed(2)}`,
          data: { serviceId, type: 'service_completed' },
        });
      }
    },
  });

  return {
    ok: true,
    finalCents: final.totalCents,
    waitingMinutes: insurerJob ? 0 : waitingMinutes,
    billedToInsurer: insurerJob,
  };
});

/**
 * Confirms cash in hand and closes the job.
 *
 * A mismatch between what was owed and what was collected is flagged rather
 * than rejected: the chofer is standing in front of the customer and the money
 * has already changed hands, so refusing the write would only lose the record.
 */
export const confirmCashCollected = onCall({ region, cors: true }, async (request) => {
  const parsed = serviceOnly
    .extend({
      amountCents: z.number().int().min(0),
      discrepancyReason: z.string().max(300).nullish(),
    })
    .safeParse(request.data);
  if (!parsed.success) throw invalidArgument('Datos inválidos.');

  const { uid } = await requireActiveDriver(request);
  const { serviceId, amountCents, discrepancyReason } = parsed.data;

  const service = await loadService(serviceId);
  assertAssigned(service, uid);
  // An insurer's tow is billed to the company; there is no cash to confirm,
  // and marking it paid would take it off the month's invoice.
  if (isInsurerJob(service)) {
    throw precondition(
      Code.invalidTransition,
      'Este servicio se factura a la aseguradora. No hay efectivo que cobrar.',
    );
  }

  const expected =
    ((service['final'] as Record<string, unknown> | undefined)?.['totalCents'] as number) ??
    ((service['quote'] as Record<string, unknown> | undefined)?.['totalCents'] as number) ??
    0;

  const mismatch = amountCents !== expected;
  if (mismatch && !discrepancyReason) {
    throw precondition(
      Code.invalidInput,
      'El monto no coincide. Explica por qué antes de confirmar.',
      { expectedCents: expected },
    );
  }

  await applyTransition({
    serviceId,
    event: ServiceEventName.confirmCashCollected,
    actorId: uid,
    actorRole: UserRole.driver,
    meta: { amountCents, expected, discrepancyReason: discrepancyReason ?? null },
    patch: {
      'payment.capturedCents': amountCents,
      'payment.cashCollectedBy': uid,
      ...(mismatch ? { needsReview: true } : {}),
    },
    // What the chofer now holds for the company, in the same write as the job
    // being marked paid: the office's corte reads this.
    inTransaction: ({ transaction }) => {
      transaction.update(Paths.driver(uid), {
        cashOnHandCents: FieldValue.increment(amountCents),
        updatedAt: FieldValue.serverTimestamp(),
      });
    },
  });

  return { ok: true };
});

// ---------------------------------------------------------------------------
// Giving up
// ---------------------------------------------------------------------------

/**
 * The customer cancels.
 *
 * A fee applies only once a chofer has actually been driving toward them for
 * longer than the grace period — cancelling ten seconds after requesting costs
 * nothing, because nobody has done any work.
 */
export const cancelService = onCall({ region, cors: true }, async (request) => {
  const parsed = serviceOnly
    .extend({ reason: z.string().max(300).default('client_request') })
    .safeParse(request.data);
  if (!parsed.success) throw invalidArgument('Datos inválidos.');

  const caller = requireAuth(request);
  const { serviceId, reason } = parsed.data;

  const service = await loadService(serviceId);
  const clientId = (service['clientId'] as string | undefined) || '';
  const isOwner = clientId !== '' && clientId === caller.uid;
  const isStaff = caller.role === UserRole.admin || caller.role === UserRole.ops;

  // The company that ordered it, as its member records say right now.
  let isInsurer = false;
  if (caller.role === UserRole.insurer) {
    const insurer = await requireActiveInsurer(request);
    isInsurer =
      typeof service['insurerId'] === 'string' && service['insurerId'] === insurer.insurerId;
  }

  if (!isOwner && !isStaff && !isInsurer) {
    throw precondition(Code.invalidTransition, 'Este servicio no es tuyo.');
  }

  const pricing = await loadPricing();
  const acceptedAt = (
    (service['timeline'] as Record<string, unknown> | undefined)?.['acceptedAt'] as
      | FirebaseFirestore.Timestamp
      | undefined
  )?.toDate();

  // An insurer's tow is only charged when the company itself cancels it: the
  // office cancelling one is the office's own business.
  const insurerJob = typeof service['insurerId'] === 'string' && service['insurerId'] !== '';
  const feeCents =
    insurerJob && !isInsurer ? 0 : cancellationFeeCents(pricing, acceptedAt ?? null, new Date());

  // The chofer comes from the transaction's own read, not the one above. A
  // chofer who accepted between the two was otherwise never freed: the service
  // ended up cancelled with them on it, and they stayed "Ocupado" on an empty
  // screen, skipped by dispatch and unable to go offline.
  let driverId: string | undefined;

  await applyTransition({
    serviceId,
    event: ServiceEventName.cancelService,
    actorId: caller.uid,
    actorRole: isOwner ? UserRole.client : isInsurer ? UserRole.insurer : (caller.role as UserRole),
    meta: { reason, feeCents },
    patch: {
      cancellation: {
        by: isOwner ? CancelledBy.client : isInsurer ? CancelledBy.insurer : CancelledBy.admin,
        reason,
        reasonCode: reason,
        feeCents,
        actorId: caller.uid,
      },
      // The fee goes on the company's next monthly invoice.
      ...(insurerJob && feeCents > 0 ? { 'payment.status': PaymentStatus.toInvoice } : {}),
    },

    inTransaction: ({ transaction, service: fresh }) => {
      driverId = fresh['driverId'] as string | undefined;

      // An insurer's tow has no customer profile to release.
      if (clientId) {
        transaction.update(Paths.user(clientId), {
          activeServiceId: FieldValue.delete(),
          updatedAt: FieldValue.serverTimestamp(),
        });
      }

      if (driverId) {
        transaction.update(Paths.driver(driverId), {
          currentServiceId: FieldValue.delete(),
          updatedAt: FieldValue.serverTimestamp(),
        });
      }
    },

    afterCommit: async () => {
      // The cancellation fee is recorded on the service for the office to
      // collect: with no card on file there is nothing here to charge it to.
      if (!driverId) return;
      await Paths.live(driverId).update({
        state: DriverLiveState.idle,
        serviceId: null,
        updatedAt: Date.now(),
      });
      await notify({
        uid: driverId,
        audience: 'driver',
        title: 'Servicio cancelado',
        body: isInsurer
          ? 'La aseguradora canceló el servicio.'
          : 'El cliente canceló el servicio.',
        data: { serviceId, type: 'service_cancelled' },
      });
    },
  });

  return { ok: true, feeCents };
  },
);

/**
 * The chofer drops the job.
 *
 * Back into the pool rather than cancelled: the customer still needs a tow, and
 * making them re-request would put them at the back of their own queue. The
 * chofer is excluded from the re-dispatch so the cascade does not immediately
 * offer it back to them.
 */
export const cancelByDriver = onCall({ region, cors: true }, async (request) => {
  const parsed = serviceOnly
    .extend({ reason: z.nativeEnum(DriverCancelReason) })
    .safeParse(request.data);
  if (!parsed.success) throw invalidArgument('Elige un motivo.');

  const { uid } = await requireActiveDriver(request);
  const { serviceId, reason } = parsed.data;

  const service = await loadService(serviceId);
  assertAssigned(service, uid);

  await applyTransition({
    serviceId,
    event: ServiceEventName.cancelByDriver,
    actorId: uid,
    actorRole: UserRole.driver,
    meta: { reason },
    patch: {
      driverId: FieldValue.delete(),
      driverName: '',
      driverPhone: '',
      truckId: FieldValue.delete(),
      truckPlate: '',
      assignedAt: FieldValue.delete(),
      'timeline.acceptedAt': FieldValue.delete(),
      'timeline.arrivedAt': FieldValue.delete(),
      'dispatch.rejectedBy': FieldValue.arrayUnion(uid),
    },

    inTransaction: ({ transaction }) => {
      transaction.update(Paths.driver(uid), {
        currentServiceId: FieldValue.delete(),
        cancellations: FieldValue.increment(1),
        updatedAt: FieldValue.serverTimestamp(),
      });
    },

    afterCommit: async ({ service: s }) => {
      await Paths.live(uid).update({
        state: DriverLiveState.idle,
        serviceId: null,
        updatedAt: Date.now(),
      });

      const clientId = s['clientId'] as string | undefined;
      if (clientId) {
        await notify({
          uid: clientId,
          audience: 'client',
          title: 'Buscando otra grúa',
          body: 'El chofer no pudo continuar. Ya estamos asignando otra.',
          data: { serviceId, type: 'redispatching' },
        });
      }
    },
  });

  // Straight back into the cascade — the customer is already waiting.
  await dispatchNext(serviceId);
  return { ok: true };
});
