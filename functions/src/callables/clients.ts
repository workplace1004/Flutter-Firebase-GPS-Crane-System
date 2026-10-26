import { getAuth } from 'firebase-admin/auth';
import { getStorage } from 'firebase-admin/storage';
import { onCall } from 'firebase-functions/v2/https';
import { logger } from 'firebase-functions/v2';
import { z } from 'zod';

import { ACTIVE_STATUSES } from '../lib/enums.js';
import { Code, invalidArgument, precondition } from '../lib/errors.js';
import { FieldValue, Paths, db } from '../lib/firestore.js';
import { requireAdmin, requireStaff } from '../lib/guards.js';
import { audit } from './admin.js';
import { region } from './region.js';

/**
 * The office's hand on a customer's account: correcting their details,
 * blocking and unblocking them, and deleting them.
 *
 * The phone number is not editable here: it is how the customer signs in,
 * and changing it would lock them out of their own account.
 */

/** A customer's record, or a refusal that says so. */
async function loadClient(clientId: string): Promise<FirebaseFirestore.DocumentData> {
  const user = (await Paths.user(clientId).get()).data();
  // Only customers: a chofer's or staff member's profile document is not
  // this screen's to change.
  if (!user || (user['role'] ?? 'client') !== 'client') {
    throw precondition(Code.notFound, 'Cliente no encontrado.');
  }
  return user;
}

/** RNC (9 digits) or cédula (11) for a crédito-fiscal invoice; empty for none. */
const rnc = z
  .string()
  .trim()
  .transform((v) => v.replace(/\D/g, ''))
  .refine((v) => v === '' || v.length === 9 || v.length === 11, {
    message: 'El RNC tiene 9 dígitos, o 11 si es una cédula.',
  });

const updateClientInput = z.object({
  clientId: z.string().min(1).max(128),
  name: z.string().trim().min(2).max(80),
  email: z.union([z.literal(''), z.string().trim().email().max(120)]),
  rnc,
  address: z.string().trim().max(200).default(''),
});

/** Corrects a customer's name, email, RNC or address. Staff only. */
export const updateClient = onCall({ region, cors: true }, async (request) => {
  const parsed = updateClientInput.safeParse(request.data);
  if (!parsed.success) {
    const rncIssue = parsed.error.issues.find((i) => i.path[0] === 'rnc');
    throw invalidArgument(rncIssue?.message ?? 'Revisa los datos del cliente.');
  }

  const caller = requireStaff(request);
  const input = parsed.data;
  const before = await loadClient(input.clientId);

  await Paths.user(input.clientId).update({
    name: input.name,
    email: input.email,
    rnc: input.rnc,
    address: input.address,
    updatedAt: FieldValue.serverTimestamp(),
  });

  await audit(caller.uid, 'updateClient', input.clientId, {
    name: [before['name'] ?? '', input.name],
    email: [before['email'] ?? '', input.email],
    rnc: [before['rnc'] ?? '', input.rnc],
  });
  return { ok: true };
});

/**
 * Blocks or unblocks a customer. A blocked customer can still sign in and
 * see their history, but `requireClient` refuses every new request. Staff
 * only; blocking needs a reason, which the office reads on the list.
 */
export const setClientBlocked = onCall({ region, cors: true }, async (request) => {
  const parsed = z
    .object({
      clientId: z.string().min(1).max(128),
      blocked: z.boolean(),
      reason: z.string().trim().max(300).default(''),
    })
    .safeParse(request.data);
  if (!parsed.success) throw invalidArgument('Datos inválidos.');

  const caller = requireStaff(request);
  const { clientId, blocked, reason } = parsed.data;
  if (blocked && reason.length < 3) {
    throw invalidArgument('Escribe por qué se bloquea a este cliente.');
  }
  await loadClient(clientId);

  await Paths.user(clientId).update({
    blocked,
    blockedReason: blocked ? reason : '',
    blockedAt: blocked ? FieldValue.serverTimestamp() : null,
    blockedBy: blocked ? caller.uid : null,
    updatedAt: FieldValue.serverTimestamp(),
  });

  await audit(caller.uid, blocked ? 'blockClient' : 'unblockClient', clientId, {
    reason,
  });
  return { ok: true };
});

/**
 * Deletes a customer for good: their sign-in, their profile with its saved
 * vehicles and places, and the photos they attached to requests. Their past
 * services and invoices stay, under the name they had, as the company's
 * history. Admin only, and never mid-tow.
 */
export const deleteClient = onCall(
  { region, cors: true, timeoutSeconds: 120 },
  async (request) => {
    const parsed = z
      .object({ clientId: z.string().min(1).max(128) })
      .safeParse(request.data);
    if (!parsed.success) throw invalidArgument('Datos inválidos.');

    const caller = requireAdmin(request);
    const { clientId } = parsed.data;
    const user = await loadClient(clientId);

    const active = await Paths.services()
      .where('clientId', '==', clientId)
      .where('status', 'in', [...ACTIVE_STATUSES])
      .limit(1)
      .get();
    if (!active.empty) {
      throw precondition(
        Code.invalidTransition,
        'Este cliente tiene un servicio en curso. Elimínalo cuando termine.',
        { serviceId: active.docs[0]!.id },
      );
    }

    await db.recursiveDelete(Paths.user(clientId));
    await getStorage()
      .bucket()
      .deleteFiles({ prefix: `requests/${clientId}/` })
      .catch((error: unknown) => {
        logger.warn('client.deleteFilesFailed', { clientId, error: String(error) });
      });
    await getAuth()
      .deleteUser(clientId)
      .catch((error: unknown) => {
        if ((error as { code?: string }).code !== 'auth/user-not-found') throw error;
      });

    await audit(caller.uid, 'deleteClient', clientId, {
      name: (user['name'] as string | undefined) ?? '',
    });
    logger.info('client.deleted', { clientId, by: caller.uid });
    return { ok: true };
  },
);
