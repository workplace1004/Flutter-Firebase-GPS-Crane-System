import { onCall } from 'firebase-functions/v2/https';
import { z } from 'zod';

import { CONTACT_OPEN_STATUSES, ServiceStatus } from '../lib/enums.js';
import { Code, invalidArgument, precondition } from '../lib/errors.js';
import {
  ALL_TAGS,
  applyClientRating,
  applyRating,
  CLIENT_NEGATIVE_TAGS,
  CLIENT_POSITIVE_TAGS,
  type ClientRatingSummary,
  clientTagsFor,
  type DriverRatingSummary,
  needsClientReview,
  needsReview,
  RATING_WINDOW_DAYS,
  tagsFor,
  withinRatingWindow,
} from '../lib/driverRating.js';
import { db, FieldValue, Paths } from '../lib/firestore.js';
import { requireActiveDriver, requireAuth, requireStaff } from '../lib/guards.js';
import { alertAdmins } from '../lib/push.js';
import { audit } from './admin.js';
import { region } from './region.js';

/** Where a customer's review of a chofer stands with the office. */
export const ReviewStatus = {
  /** Nothing to look at. */
  ok: 'ok',
  /** Low stars or a serious complaint: waiting for the office. */
  open: 'open',
  /** The office looked into it and wrote down what it found. */
  resolved: 'resolved',
} as const;

/**
 * Rating a finished job, and the chofer's live ETA.
 *
 * Both are small, and both exist because the alternative is a client write to a
 * collection the rules deny — ratings feed a chofer's dispatch score, and the
 * tracking document is what the customer's map reads.
 */

/**
 * Rates the other party.
 *
 * A customer's rating of the chofer is the one that matters: it carries stars,
 * tags and a comment, feeds the chofer's summary and dispatch score, and files
 * a review the office sees. A chofer's rating of the customer is only kept on
 * the service.
 *
 * Everything happens in one transaction. Checking "already rated" and writing
 * the rating separately let a double tap count twice, and recomputing the
 * average from a second read let two ratings at once overwrite each other.
 * Re-rating is refused rather than overwritten: silently replacing a rating
 * would let somebody walk one back after a dispute.
 */
export const rateService = onCall({ region, cors: true }, async (request) => {
  const parsed = z
    .object({
      serviceId: z.string().min(1).max(64),
      stars: z.number().int().min(1).max(5),
      tags: z.array(z.string().max(40)).max(ALL_TAGS.length + CLIENT_POSITIVE_TAGS.length + CLIENT_NEGATIVE_TAGS.length).default([]),
      comment: z.string().max(500).nullish(),
    })
    .safeParse(request.data);
  if (!parsed.success) throw invalidArgument('Elige entre 1 y 5 estrellas.');

  const caller = requireAuth(request);
  const { serviceId, stars } = parsed.data;
  const comment = (parsed.data.comment ?? '').trim();

  const review = await db.runTransaction(async (transaction) => {
    const snap = await transaction.get(Paths.service(serviceId));
    const service = snap.data();
    if (!service) throw precondition(Code.notFound, 'Este servicio ya no existe.');

    const isClient = service['clientId'] === caller.uid;
    const isDriver = service['driverId'] === caller.uid;
    if (!isClient && !isDriver) {
      throw precondition(Code.invalidTransition, 'Este servicio no es tuyo.');
    }

    // Rating a job that has not finished is rating something that has not
    // happened yet.
    const status = service['status'] as ServiceStatus;
    if (status !== ServiceStatus.completed && status !== ServiceStatus.closed) {
      throw precondition(
        Code.invalidTransition,
        'Puedes calificar cuando termine el servicio.',
      );
    }

    const timeline = (service['timeline'] ?? {}) as Record<string, unknown>;
    const finishedAt = (timeline['completedAt'] as FirebaseFirestore.Timestamp | undefined)
      ?.toDate();
    if (!withinRatingWindow(finishedAt, new Date())) {
      throw precondition(
        Code.invalidTransition,
        `Solo puedes calificar durante ${RATING_WINDOW_DAYS} días después del servicio.`,
      );
    }

    // Each side has its own tags: a chofer is not "puntual" to a customer
    // who "no estaba en el lugar".
    const tags: string[] = isClient
      ? tagsFor(stars, parsed.data.tags)
      : clientTagsFor(stars, parsed.data.tags);

    const side = isClient ? 'clientToDriver' : 'driverToClient';
    const ratings = (service['ratings'] ?? {}) as Record<string, unknown>;
    if (ratings[side]) {
      throw precondition(Code.invalidInput, 'Ya calificaste este servicio.');
    }

    const driverId = service['driverId'] as string | undefined;
    const clientId = (service['clientId'] as string | undefined) ?? '';
    // An insurer's tow has no customer account to rate.
    if (isDriver && !clientId) {
      throw precondition(
        Code.invalidTransition,
        'Este servicio no tiene un cliente de la app para calificar.',
      );
    }
    const driverSnap =
      isClient && driverId ? await transaction.get(Paths.driver(driverId)) : undefined;
    const clientSnap = isDriver ? await transaction.get(Paths.user(clientId)) : undefined;

    // Reads above, writes below: a transaction refuses a read after a write.
    transaction.update(Paths.service(serviceId), {
      [`ratings.${side}`]: {
        stars,
        comment,
        tags,
        ratedAt: FieldValue.serverTimestamp(),
      },
      updatedAt: FieldValue.serverTimestamp(),
    });

    if (isDriver) {
      if (clientSnap?.exists) {
        transaction.update(Paths.user(clientId), {
          ...applyClientRating(
            (clientSnap.data() ?? {}) as Partial<ClientRatingSummary>,
            stars,
            tags,
          ),
          updatedAt: FieldValue.serverTimestamp(),
        });
      }
      return {
        kind: 'client' as const,
        flagged: needsClientReview(stars, tags),
        stars,
        comment,
        serviceCode: (service['code'] as string | undefined) ?? '',
        clientName: (service['clientName'] as string | undefined) ?? '',
        driverName: (service['driverName'] as string | undefined) ?? '',
      };
    }

    if (!isClient || !driverId || !driverSnap?.exists) return null;

    const summary = applyRating((driverSnap.data() ?? {}) as Partial<DriverRatingSummary>, {
      stars,
      tags,
      comment,
    });
    transaction.update(Paths.driver(driverId), {
      ...summary,
      updatedAt: FieldValue.serverTimestamp(),
    });

    const flagged = needsReview(stars, tags);
    const filed = {
      serviceId,
      serviceCode: (service['code'] as string | undefined) ?? '',
      driverId,
      driverName: (service['driverName'] as string | undefined) ?? '',
      clientId: service['clientId'] as string,
      clientName: (service['clientName'] as string | undefined) ?? '',
      stars,
      tags,
      comment,
      status: flagged ? ReviewStatus.open : ReviewStatus.ok,
      ratedAt: FieldValue.serverTimestamp(),
    };
    transaction.create(Paths.driverReview(serviceId), filed);
    return { kind: 'driver' as const, flagged, ...filed };
  });

  if (review?.kind === 'driver' && review.flagged) {
    await alertAdmins(
      `Calificación de ${review.stars} ★ a ${review.driverName || 'un chofer'}`,
      review.comment || `Servicio ${review.serviceCode}. Revísala en Evaluaciones.`,
      { type: 'driver_review', serviceId },
    );
  }
  if (review?.kind === 'client' && review.flagged) {
    await alertAdmins(
      `${review.driverName || 'Un chofer'} calificó con ${review.stars} ★ a ${review.clientName || 'un cliente'}`,
      review.comment || `Servicio ${review.serviceCode}.`,
      { type: 'client_review', serviceId },
    );
  }

  return { ok: true };
});

/**
 * The office closes a flagged review: it called the customer, spoke to the
 * chofer, and wrote down what it found. The rating itself is never changed.
 */
export const resolveDriverReview = onCall({ region, cors: true }, async (request) => {
  const parsed = z
    .object({
      serviceId: z.string().min(1).max(64),
      note: z.string().trim().min(3).max(1000),
    })
    .safeParse(request.data);
  if (!parsed.success) throw invalidArgument('Escribe qué se hizo con esta evaluación.');

  const caller = requireStaff(request);
  const { serviceId, note } = parsed.data;

  await db.runTransaction(async (transaction) => {
    const snap = await transaction.get(Paths.driverReview(serviceId));
    const review = snap.data();
    if (!review) throw precondition(Code.notFound, 'Esa evaluación no existe.');
    if (review['status'] !== ReviewStatus.open) {
      throw precondition(Code.invalidTransition, 'Esa evaluación no está pendiente.');
    }
    transaction.update(Paths.driverReview(serviceId), {
      status: ReviewStatus.resolved,
      resolutionNote: note,
      resolvedBy: caller.uid,
      resolvedAt: FieldValue.serverTimestamp(),
    });
  });

  await audit(caller.uid, 'driverReview.resolve', serviceId, { note });
  return { ok: true };
});

/**
 * Publishes the chofer's ETA for the customer's map.
 *
 * The position itself is mirrored from RTDB by a trigger; this carries the
 * estimate, which only the chofer's device can compute — it knows the remaining
 * polyline and the current speed, and recomputing that server-side would mean a
 * Routes API call every twenty seconds per active tow.
 */
export const publishEta = onCall({ region, cors: true }, async (request) => {
  const parsed = z
    .object({
      serviceId: z.string().min(1).max(64),
      etaSeconds: z.number().int().min(0).max(24 * 3600),
      remainingMeters: z.number().int().min(0).max(2_000_000),
    })
    .safeParse(request.data);
  if (!parsed.success) throw invalidArgument('Datos inválidos.');

  const { uid } = await requireActiveDriver(request);
  const { serviceId, etaSeconds, remainingMeters } = parsed.data;

  const snap = await Paths.service(serviceId).get();
  const service = snap.data();
  if (!service) throw precondition(Code.notFound, 'Este servicio ya no existe.');
  if (service['driverId'] !== uid) {
    throw precondition(Code.invalidTransition, 'Este servicio no es tuyo.');
  }
  if (!CONTACT_OPEN_STATUSES.includes(service['status'] as ServiceStatus)) {
    // Nothing is moving, so an ETA would be a number with no meaning.
    return { ok: false };
  }

  await Paths.tracking(serviceId).set(
    { etaSeconds, remainingMeters, updatedAt: FieldValue.serverTimestamp() },
    { merge: true },
  );

  return { ok: true };
});
