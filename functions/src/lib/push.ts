import { getMessaging } from 'firebase-admin/messaging';
import type { Message, MulticastMessage } from 'firebase-admin/messaging';
import { logger } from 'firebase-functions/v2';

import { Paths } from './firestore.js';

/**
 * Push delivery.
 *
 * Two things here are not defaults and matter a lot:
 *
 * * **An offer is a data-only message.** No `notification` block, high priority,
 *   a TTL matching the offer and a collapse key. The chofer app draws its own
 *   ringing UI from the data; a system notification would be a banner the chofer
 *   misses at 70 km/h. The short TTL means a phone that comes back online after
 *   the offer expired is not woken by a job somebody else already took.
 * * **Dead tokens are pruned.** FCM reports `registration-token-not-registered`
 *   for uninstalled apps; leaving those in place means every send fans out to a
 *   growing list of nothing.
 */

export type Audience = 'client' | 'driver';

async function tokensFor(uid: string, audience: Audience): Promise<string[]> {
  const collection =
    audience === 'driver' ? Paths.driverTokens(uid) : Paths.userTokens(uid);
  const snap = await collection.get();
  return snap.docs.map((doc) => doc.id);
}

async function pruneDeadTokens(
  uid: string,
  audience: Audience,
  tokens: string[],
  responses: { success: boolean; error?: { code: string } }[],
): Promise<void> {
  const dead: string[] = [];
  responses.forEach((response, index) => {
    if (response.success) return;
    const code = response.error?.code ?? '';
    if (
      code.includes('registration-token-not-registered') ||
      code.includes('invalid-registration-token') ||
      code.includes('invalid-argument')
    ) {
      const token = tokens[index];
      if (token) dead.push(token);
    }
  });

  if (dead.length === 0) return;

  const collection =
    audience === 'driver' ? Paths.driverTokens(uid) : Paths.userTokens(uid);
  await Promise.all(dead.map((token) => collection.doc(token).delete()));
  logger.info('push.prunedTokens', { uid, audience, count: dead.length });
}

/** A normal, visible notification. */
export async function notify(options: {
  uid: string;
  audience: Audience;
  title: string;
  body: string;
  data?: Record<string, string>;
  channel?: string;
}): Promise<void> {
  const tokens = await tokensFor(options.uid, options.audience);
  if (tokens.length === 0) return;

  const message: MulticastMessage = {
    tokens,
    notification: { title: options.title, body: options.body },
    data: { ...options.data },
    android: {
      priority: 'high',
      notification: {
        channelId: options.channel ?? 'service_updates',
        // Collapsing on the service keeps a five-step tow from stacking five
        // notifications the customer has to dismiss.
        tag: options.data?.['serviceId'],
      },
    },
    apns: {
      headers: { 'apns-priority': '10' },
      payload: { aps: { sound: 'default', 'interruption-level': 'active' } },
    },
  };

  const response = await getMessaging().sendEachForMulticast(message);
  await pruneDeadTokens(options.uid, options.audience, tokens, response.responses);
}

/**
 * The ringing offer.
 *
 * Data-only and short-lived, so the chofer app controls the presentation and a
 * stale offer cannot wake a phone that was out of coverage.
 */
export async function sendOffer(options: {
  driverId: string;
  serviceId: string;
  ttlSeconds: number;
  payload: Record<string, string>;
}): Promise<void> {
  const tokens = await tokensFor(options.driverId, 'driver');
  if (tokens.length === 0) {
    logger.warn('push.offerWithNoTokens', { driverId: options.driverId });
    return;
  }

  const ttlMs = options.ttlSeconds * 1000;
  const expiration = Math.floor(Date.now() / 1000) + options.ttlSeconds;

  const message: MulticastMessage = {
    tokens,
    data: {
      type: 'offer',
      serviceId: options.serviceId,
      // So the notification the app draws goes away when the offer does.
      ttlSeconds: `${options.ttlSeconds}`,
      ...options.payload,
    },
    android: {
      priority: 'high',
      ttl: ttlMs,
      // One offer on screen at a time; a newer one replaces the old.
      collapseKey: 'grua_offer',
    },
    apns: {
      headers: {
        'apns-push-type': 'alert',
        'apns-priority': '10',
        'apns-expiration': `${expiration}`,
        'apns-collapse-id': 'grua_offer',
      },
      payload: {
        aps: {
          // Time-sensitive breaks through Focus, which a chofer on a highway
          // very often has on.
          'interruption-level': 'time-sensitive',
          contentAvailable: true,
          sound: 'offer.caf',
          alert: {
            title: 'Nuevo servicio',
            body: 'Tienes una solicitud de grúa',
          },
        },
      },
    },
  };

  const response = await getMessaging().sendEachForMulticast(message);
  await pruneDeadTokens(options.driverId, 'driver', tokens, response.responses);
}

/** Silently tells the chofer app to take a dead offer off the screen. */
export async function dismissOffer(driverId: string, serviceId: string): Promise<void> {
  const tokens = await tokensFor(driverId, 'driver');
  if (tokens.length === 0) return;

  await getMessaging().sendEachForMulticast({
    tokens,
    data: { type: 'offer_cancelled', serviceId },
    android: { priority: 'high', collapseKey: 'grua_offer' },
    apns: {
      headers: { 'apns-push-type': 'background', 'apns-priority': '5' },
      payload: { aps: { contentAvailable: true } },
    },
  });
}

/** Wakes the dispatchers when the cascade gives up. */
export async function alertAdmins(title: string, body: string, data: Record<string, string> = {}): Promise<void> {
  const message: Message = {
    topic: 'admins',
    notification: { title, body },
    data,
    android: { priority: 'high', notification: { channelId: 'admin' } },
  };
  try {
    await getMessaging().send(message);
  } catch (error) {
    logger.error('push.alertAdmins failed', { error });
  }
}
