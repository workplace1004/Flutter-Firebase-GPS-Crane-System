import { logger } from 'firebase-functions/v2';

import {
  DriverLiveState,
  OfferState,
  ServiceEventName,
  ServiceStatus,
} from '../lib/enums.js';
import { Code, precondition } from '../lib/errors.js';
import { FieldValue, Paths, db } from '../lib/firestore.js';
import { dismissOffer, notify } from '../lib/push.js';
import { averageRating } from '../lib/driverRating.js';
import { applyTransition } from '../lib/stateMachine.js';
import { dispatchNext } from './dispatchNext.js';

/**
 * Accepting, rejecting and expiring an offer.
 *
 * This is where the double-accept race lives. Two choferes tapping ACEPTAR 50
 * milliseconds apart both read `offered`; exactly one may win, and the loser
 * must be told "otro chofer tomó el servicio" rather than something vague,
 * because the two outcomes call for completely different behaviour from them.
 */

/**
 * Takes the job, if it is still there.
 *
 * Everything that must hold is checked in one transaction against fresh reads:
 * the offer is still open, it has not expired, the service is still offered,
 * and the chofer is not already towing something.
 */
export async function acceptOffer(options: {
  serviceId: string;
  driverId: string;
  driver: FirebaseFirestore.DocumentData;
}): Promise<void> {
  const { serviceId, driverId, driver } = options;

  await applyTransition({
    serviceId,
    event: ServiceEventName.acceptService,
    actorId: driverId,
    actorRole: 'driver',
    meta: { driverId },

    inTransaction: async ({ transaction, service }) => {
      const offerRef = Paths.offer(serviceId, driverId);
      const offerSnap = await transaction.get(offerRef);
      const offer = offerSnap.data();

      if (!offer) {
        // No offer for this chofer. Either it was never theirs, or the cascade
        // has already moved on and deleted nothing — either way, taken.
        throw precondition(Code.alreadyTaken, 'Otro chofer tomó el servicio.');
      }

      if (offer['state'] !== OfferState.sent) {
        throw offer['state'] === OfferState.expired
          ? precondition(Code.offerExpired, 'La oferta expiró.')
          : precondition(Code.alreadyTaken, 'Otro chofer tomó el servicio.');
      }

      const expiresAt = (offer['expiresAt'] as FirebaseFirestore.Timestamp | undefined)
        ?.toMillis();
      if (expiresAt && Date.now() > expiresAt) {
        throw precondition(Code.offerExpired, 'La oferta expiró.');
      }

      // Re-read rather than trusting the copy the guard loaded: an admin could
      // have assigned this chofer to something else in the meantime.
      const driverRef = Paths.driver(driverId);
      const driverSnap = await transaction.get(driverRef);
      const current = driverSnap.data();
      if (!current) throw precondition(Code.driverInactive, 'Cuenta no encontrada.');

      const busyWith = current['currentServiceId'] as string | undefined;
      if (busyWith && busyWith !== serviceId) {
        throw precondition(Code.driverBusy, 'Ya tienes un servicio asignado.');
      }

      transaction.update(offerRef, {
        state: OfferState.accepted,
        respondedAt: FieldValue.serverTimestamp(),
      });

      transaction.update(driverRef, {
        currentServiceId: serviceId,
        offersAccepted: FieldValue.increment(1),
        updatedAt: FieldValue.serverTimestamp(),
      });

      const truckId = current['assignedTruckId'] as string | undefined;

      transaction.update(Paths.service(serviceId), {
        driverId,
        driverName: current['name'] ?? '',
        driverPhone: current['phone'] ?? '',
        driverPhotoUrl: current['photoUrl'] ?? '',
        // What the customer reads: the plain average, 0 before any rating.
        driverRating: averageRating(
          (current['ratingSum'] as number | undefined) ?? 0,
          (current['ratingCount'] as number | undefined) ?? 0,
        ),
        truckId: truckId ?? null,
        truckPlate: current['assignedTruckPlate'] ?? '',
        assignedAt: FieldValue.serverTimestamp(),
        assignmentMode: 'auto',
        'timeline.acceptedAt': FieldValue.serverTimestamp(),
      });

      // Kept for the log, not read again — but a service with no client is a
      // bug worth catching in the audit trail rather than at the roadside.
      void service;
    },

    afterCommit: async ({ service }) => {
      // The RTDB node drives dispatch eligibility, so it must stop advertising
      // this chofer as idle the moment they are committed to a job.
      await Paths.live(driverId).update({
        state: DriverLiveState.onService,
        serviceId,
        updatedAt: Date.now(),
      });

      const clientId = service['clientId'] as string | undefined;
      if (clientId) {
        await notify({
          uid: clientId,
          audience: 'client',
          title: 'Tu grúa va en camino',
          body: `${driver['name'] ?? 'Un chofer'} viene por ti.`,
          data: { serviceId, type: 'driver_assigned' },
        });
      }
    },
  });
}

/**
 * Declines, and immediately offers the job to the next chofer.
 *
 * The cascade continues rather than waiting for the timer: a chofer who says no
 * has given us information, and making the customer wait out the remaining 20
 * seconds for nothing is the one thing a rejection should never cost them.
 */
export async function rejectOffer(options: {
  serviceId: string;
  driverId: string;
  reason?: string;
}): Promise<void> {
  const { serviceId, driverId, reason } = options;

  const moved = await closeOffer({
    serviceId,
    driverId,
    to: OfferState.rejected,
    event: ServiceEventName.rejectService,
    actorId: driverId,
    actorRole: 'driver',
    meta: { reason: reason ?? 'unspecified' },
  });

  if (moved) await dispatchNext(serviceId);
}

/**
 * Expires an unanswered offer and cascades.
 *
 * Called by the Cloud Task at `t+27s` and by the sweeper for anything the task
 * missed. Idempotent: an offer already answered is left alone.
 */
export async function expireOffer(options: {
  serviceId: string;
  driverId: string;
}): Promise<void> {
  const { serviceId, driverId } = options;

  // A retry slot with no chofer — the cascade had run out of radius but still
  // had time. Just try again.
  if (!driverId) {
    await dispatchNext(serviceId);
    return;
  }

  const moved = await closeOffer({
    serviceId,
    driverId,
    to: OfferState.expired,
    event: ServiceEventName.expireOffer,
    actorId: 'system',
    actorRole: 'system',
    meta: {},
  });

  if (!moved) return;

  // Take the ringing screen down; the chofer should not be looking at a job
  // that is already being offered to somebody else.
  await dismissOffer(driverId, serviceId);
  await dispatchNext(serviceId);
}

/**
 * Marks an offer dead and puts the service back in the pool.
 *
 * Returns false when there was nothing to do — the offer was already answered,
 * or the service moved on. Callers use that to avoid cascading twice.
 */
async function closeOffer(options: {
  serviceId: string;
  driverId: string;
  to: typeof OfferState.rejected | typeof OfferState.expired;
  event: ServiceEventName;
  actorId: string;
  actorRole: 'driver' | 'system';
  meta: Record<string, unknown>;
}): Promise<boolean> {
  const { serviceId, driverId, to, event, actorId, actorRole, meta } = options;

  const offerRef = Paths.offer(serviceId, driverId);
  const serviceRef = Paths.service(serviceId);
  let shouldCascade = false;

  await db.runTransaction(async (transaction) => {
    const [offerSnap, serviceSnap] = await Promise.all([
      transaction.get(offerRef),
      transaction.get(serviceRef),
    ]);

    const offer = offerSnap.data();
    const service = serviceSnap.data();
    if (!offer || !service) return;

    // Already accepted, already expired, or superseded. Nothing to do, and
    // saying so is what makes this safe to call twice.
    if (offer['state'] !== OfferState.sent) return;
    if (service['status'] !== ServiceStatus.offered) return;

    transaction.update(offerRef, {
      state: to,
      respondedAt: FieldValue.serverTimestamp(),
      ...(meta['reason'] ? { rejectionReason: meta['reason'] } : {}),
    });

    transaction.update(serviceRef, {
      status: ServiceStatus.pendingDispatch,
      'dispatch.rejectedBy': FieldValue.arrayUnion(driverId),
      'dispatch.round': FieldValue.increment(1),
      'dispatch.offerExpiresAt': FieldValue.delete(),
      updatedAt: FieldValue.serverTimestamp(),
    });

    transaction.create(Paths.events(serviceId).doc(), {
      event,
      from: ServiceStatus.offered,
      to: ServiceStatus.pendingDispatch,
      actorId,
      actorRole,
      meta: { driverId, ...meta },
      at: FieldValue.serverTimestamp(),
    });

    // A chofer who never answers is a chofer whose notifications are broken or
    // who is cherry-picking. Both need to show up in the panel.
    transaction.update(Paths.driver(driverId), {
      ...(to === OfferState.expired
        ? { offersMissed: FieldValue.increment(1) }
        : { offersRejected: FieldValue.increment(1) }),
      updatedAt: FieldValue.serverTimestamp(),
    });

    shouldCascade = true;
  });

  if (shouldCascade) {
    logger.info('dispatch.offerClosed', { serviceId, driverId, to });
  }
  return shouldCascade;
}
