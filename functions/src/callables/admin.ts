import { getAuth } from 'firebase-admin/auth';
import { getDownloadURL, getStorage } from 'firebase-admin/storage';
import { onCall } from 'firebase-functions/v2/https';
import { logger } from 'firebase-functions/v2';
import { z } from 'zod';

import {
  AssignmentMode,
  DocumentReviewState,
  DriverDocumentType,
  DriverLiveState,
  DriverStatus,
  LicenseVerificationState,
  OperatorReviewState,
  ServiceEventName,
  UserRole,
} from '../lib/enums.js';
import { dispatchNext } from '../dispatch/dispatchNext.js';
import { type Quote, confirmedQuote } from '../lib/pricing.js';
import { Code, invalidArgument, permissionDenied, precondition } from '../lib/errors.js';
import { FieldValue, Paths, db } from '../lib/firestore.js';
import { requireAdmin, requireAppCheck, requireAuth, requireStaff } from '../lib/guards.js';
import { notify } from '../lib/push.js';
import { averageRating, PRIOR_RATING } from '../lib/driverRating.js';
import { applyTransition } from '../lib/stateMachine.js';
import { region } from './region.js';

/**
 * Everything the office does, plus the one door a chofer opens themselves.
 *
 * A chofer can ask for an account from the driver app (`registerDriver`), but
 * asking is all it does. An account created from a phone must never be able to
 * work without documents on file, insurance the company has not seen, or a
 * truck nobody has inspected — so every account, whoever opened it, starts
 * `inactive`, and only an admin clears it. Every mutation writes an audit entry
 * naming who did it.
 */

/** Records who changed what. Nothing the office does writes without one. */
export async function audit(
  actorId: string,
  action: string,
  target: string,
  details: Record<string, unknown> = {},
): Promise<void> {
  await Paths.audit().add({
    actorId,
    action,
    target,
    details,
    at: FieldValue.serverTimestamp(),
  });
}

/** Dominican cédula: 11 digits, with a check digit. */
export function isValidCedula(raw: string): boolean {
  const digits = raw.replace(/\D/g, '');
  if (digits.length !== 11) return false;

  // Luhn-style alternating 1/2 weighting, as used by the JCE.
  let sum = 0;
  for (let i = 0; i < 10; i++) {
    const weight = i % 2 === 0 ? 1 : 2;
    let product = Number(digits[i]) * weight;
    if (product > 9) product -= 9;
    sum += product;
  }
  const check = (10 - (sum % 10)) % 10;
  return check === Number(digits[10]);
}

// RNC is 9 digits for a company, 11 for a persona física trading as one.
const rncSchema = z
  .string()
  .max(20)
  .default('')
  .refine((v) => v === '' || /^\d{9}$|^\d{11}$/.test(v.replace(/\D/g, '')), {
    message: 'RNC inválido',
  });

/**
 * The fields every new chofer starts with, however the account was opened.
 *
 * Spread last into the record so no call site can open an account that is
 * already cleared to work.
 */
function newDriverDefaults() {
  return {
    status: DriverStatus.inactive,
    isOnline: false,
    rating: PRIOR_RATING,
    ratingCount: 0,
    ratingSum: 0,
    completedServices: 0,
    offersSent: 0,
    offersAccepted: 0,
    offersRejected: 0,
    offersMissed: 0,
    cancellations: 0,
    cashOwedCents: 0,
    archived: false,
    createdAt: FieldValue.serverTimestamp(),
    updatedAt: FieldValue.serverTimestamp(),
  };
}

const createDriverInput = z.object({
  name: z.string().min(3).max(120),
  cedula: z.string().min(11).max(20),
  phone: z.string().min(10).max(20),
  email: z.string().email().max(200),
  licenseNumber: z.string().max(40).default(''),
  licenseExpiry: z.string().datetime().nullish(),
  truckId: z.string().max(64).nullish(),
  // Coverage zones are a dispatch hint, not a restriction: an empty list means
  // the chofer is offered work anywhere the company covers.
  zones: z.array(z.string().max(60)).max(20).default([]),
  companyName: z.string().max(120).default(''),
  rnc: rncSchema,
  // Six is Auth's own floor. The office sets this by hand for an account it
  // is handing over in person — self-registration in `registerDriverInput`
  // still asks for eight, since nobody is standing there to say it out loud.
  initialPassword: z.string().min(6).max(128).nullish(),
});

/**
 * Creates a chofer account.
 *
 * The account starts `inactive` regardless of what the caller asks for. It
 * becomes active only once documents are verified, which is the one gate
 * between the office and a grúa on the road with lapsed insurance.
 */
export const createDriver = onCall({ region, cors: true }, async (request) => {
  const parsed = createDriverInput.safeParse(request.data);
  if (!parsed.success) throw invalidArgument('Revisa los datos del chofer.');

  const caller = requireAdmin(request);
  const input = parsed.data;

  if (!isValidCedula(input.cedula)) {
    throw invalidArgument('La cédula no es válida.');
  }

  const cedula = input.cedula.replace(/\D/g, '');

  // A duplicate cédula means either a typo or a second account for somebody who
  // already has one; both need a human, not a silent create.
  const duplicate = await Paths.drivers().where('cedula', '==', cedula).limit(1).get();
  if (!duplicate.empty) {
    throw precondition(Code.invalidInput, 'Ya existe un chofer con esa cédula.', {
      driverId: duplicate.docs[0]!.id,
    });
  }

  const password =
    input.initialPassword ?? `Grua${Math.random().toString(36).slice(2, 10)}!`;

  const user = await getAuth().createUser({
    email: input.email,
    password,
    displayName: input.name,
    phoneNumber: input.phone.startsWith('+') ? input.phone : undefined,
  });

  // The claim is what the security rules and every callable read. Setting it
  // before the document exists would leave a window where the token says
  // "driver" and there is nothing to read.
  await getAuth().setCustomUserClaims(user.uid, {
    role: UserRole.driver,
    driverId: user.uid,
  });

  const truck = input.truckId ? await Paths.truck(input.truckId).get() : null;

  await Paths.driver(user.uid).set({
    name: input.name,
    cedula,
    phone: input.phone,
    email: input.email,
    licenseNumber: input.licenseNumber,
    licenseExpiry: input.licenseExpiry ? new Date(input.licenseExpiry) : null,
    statusReason: 'Documentos pendientes de verificación',
    assignedTruckId: input.truckId ?? null,
    assignedTruckPlate: (truck?.data()?.['plate'] as string | undefined) ?? '',
    // Never '': the apps decode this field as an enum, and a chofer with no
    // grúa yet is exactly the case that has no type to write.
    truckType: (truck?.data()?.['type'] as string | undefined) || 'unknown',
    zones: input.zones,
    companyName: input.companyName,
    rnc: input.rnc.replace(/\D/g, ''),
    mustChangePassword: true,
    createdBy: caller.uid,
    ...newDriverDefaults(),
  });

  if (input.truckId) {
    await Paths.truck(input.truckId).update({
      assignedDriverId: user.uid,
      assignedDriverName: input.name,
      updatedAt: FieldValue.serverTimestamp(),
    });
  }

  await audit(caller.uid, 'createDriver', user.uid, { email: input.email });
  logger.info('driver.created', { driverId: user.uid, by: caller.uid });

  // Returned once and never again: the office reads it to the chofer, and the
  // account forces a change on first sign-in.
  return { driverId: user.uid, temporaryPassword: password };
});

const registerDriverInput = z.object({
  name: z.string().trim().min(3).max(120),
  cedula: z.string().min(11).max(20),
  phone: z.string().regex(/^\+1(809|829|849)\d{7}$/),
  email: z.string().trim().email().max(200),
  password: z.string().min(8).max(128),
  licenseNumber: z.string().trim().min(1).max(40),
  licenseExpiry: z.string().datetime(),
  companyName: z.string().trim().max(120).default(''),
  rnc: rncSchema,
});

/** What Auth refuses on sign-up, in words a chofer can act on. */
const signUpRefusals: Record<string, string> = {
  'auth/email-already-exists': 'Ya existe una cuenta con ese correo.',
  'auth/phone-number-already-exists': 'Ese teléfono ya tiene una cuenta.',
  'auth/invalid-password': 'La contraseña debe tener al menos 8 caracteres.',
  'auth/invalid-email': 'Ese correo no es válido.',
};

/**
 * A chofer asks for an account from the driver app.
 *
 * Unauthenticated by necessity — the caller has no account yet — so it grants
 * nothing a stranger should not have: the account lands `inactive`, with no
 * grúa and no zones, and cannot take a single offer until an admin has
 * verified the documents and activated it with `setDriverStatus`. It is the
 * record `createDriver` writes, marked `selfRegistered` so the office can tell
 * a request from an account it opened itself.
 */
export const registerDriver = onCall({ region, cors: true }, async (request) => {
  requireAppCheck(request);

  const parsed = registerDriverInput.safeParse(request.data);
  if (!parsed.success) throw invalidArgument('Revisa los datos del registro.');
  const input = parsed.data;

  if (!isValidCedula(input.cedula)) {
    throw invalidArgument('La cédula no es válida.');
  }

  const licenseExpiry = new Date(input.licenseExpiry);
  if (licenseExpiry.getTime() <= Date.now()) {
    throw invalidArgument('Tu licencia está vencida.');
  }

  const cedula = input.cedula.replace(/\D/g, '');

  const duplicate = await Paths.drivers().where('cedula', '==', cedula).limit(1).get();
  if (!duplicate.empty) {
    // No driverId in the details: unlike the office, a stranger is not owed
    // the id of somebody else's account.
    throw precondition(
      Code.invalidInput,
      'Ya existe un chofer con esa cédula. Comunícate con la oficina.',
    );
  }

  let uid: string;
  try {
    const user = await getAuth().createUser({
      email: input.email,
      password: input.password,
      displayName: input.name,
      phoneNumber: input.phone,
    });
    uid = user.uid;
  } catch (error) {
    const message = signUpRefusals[(error as { code?: string }).code ?? ''];
    if (message) throw precondition(Code.invalidInput, message);
    throw error;
  }

  try {
    // Claim before document, as in createDriver: the token must never say
    // "driver" with nothing behind it to read.
    await getAuth().setCustomUserClaims(uid, {
      role: UserRole.driver,
      driverId: uid,
    });

    await Paths.driver(uid).set({
      name: input.name,
      cedula,
      phone: input.phone,
      email: input.email,
      licenseNumber: input.licenseNumber,
      licenseExpiry,
      statusReason: 'Registro desde la app: documentos pendientes de verificación',
      assignedTruckId: null,
      assignedTruckPlate: '',
      truckType: 'unknown',
      zones: [],
      companyName: input.companyName,
      rnc: input.rnc.replace(/\D/g, ''),
      // The chofer chose this password; there is no temporary one to replace.
      mustChangePassword: false,
      selfRegistered: true,
      // Opened from a phone, so nobody has seen the licence: it is checked
      // once both photos are up (`verifyDriverLicense`). Accounts the office
      // opens carry no such field and skip the check.
      licenseVerification: {
        state: LicenseVerificationState.awaitingDocuments,
        attempts: 0,
        updatedAt: FieldValue.serverTimestamp(),
      },
      createdBy: uid,
      ...newDriverDefaults(),
    });
  } catch (error) {
    // An Auth user with no driver record can sign in to nothing and holds the
    // email hostage from a retry, so it does not outlive the failure.
    await getAuth()
      .deleteUser(uid)
      .catch(() => undefined);
    throw error;
  }

  await audit(uid, 'registerDriver', uid, { email: input.email });
  logger.info('driver.selfRegistered', { driverId: uid });

  return { driverId: uid };
});

const attachDocumentInput = z.object({
  driverId: z.string().min(1).max(64),
  type: z.nativeEnum(DriverDocumentType),
  storagePath: z.string().min(1).max(500),
  fileName: z.string().max(200).default(''),
  contentType: z.string().max(100).default(''),
  sizeBytes: z.number().int().nonnegative().max(10 * 1024 * 1024).default(0),
  expiresAt: z.string().datetime().nullish(),
});

/**
 * Records a document uploaded for a chofer — by the office for anyone, or by a
 * chofer for their own record, which is how a registration's licence arrives.
 *
 * The upload itself goes straight to Storage — a 10 MB scan has no business
 * travelling through a callable — but the record does not, because everything
 * under `drivers/` is server-written. Until this runs, the file is an orphan in
 * the bucket that no review screen will ever list.
 *
 * The record always lands `pending`: uploading a licence is not the same as
 * somebody having looked at it, and only the second one lets a grúa work.
 */
export const attachDriverDocument = onCall({ region, cors: true }, async (request) => {
  const parsed = attachDocumentInput.safeParse(request.data);
  if (!parsed.success) throw invalidArgument('Datos del documento inválidos.');

  const caller = requireAuth(request);
  const input = parsed.data;

  const isStaff = caller.role === UserRole.admin || caller.role === UserRole.ops;
  const isOwnRecord =
    caller.role === UserRole.driver && caller.uid === input.driverId;
  if (!isStaff && !isOwnRecord) throw permissionDenied();

  // The path is what the security rules key on, so a record pointing somewhere
  // else would hand a reviewer a file the rules never vetted.
  const expectedPrefix = `drivers/${input.driverId}/docs/`;
  if (!input.storagePath.startsWith(expectedPrefix)) {
    throw invalidArgument('La ruta del archivo no corresponde a este chofer.');
  }

  const snap = await Paths.driver(input.driverId).get();
  if (!snap.exists) throw precondition(Code.notFound, 'Chofer no encontrado.');

  await Paths.driverDocuments(input.driverId).doc(input.type).set({
    type: input.type,
    storagePath: input.storagePath,
    fileName: input.fileName,
    contentType: input.contentType,
    sizeBytes: input.sizeBytes,
    state: DocumentReviewState.pending,
    rejectionReason: '',
    uploadedBy: caller.uid,
    reviewedBy: '',
    uploadedAt: FieldValue.serverTimestamp(),
    reviewedAt: null,
    expiresAt: input.expiresAt ? new Date(input.expiresAt) : null,
  });

  await audit(caller.uid, 'attachDriverDocument', input.driverId, {
    type: input.type,
  });

  return { ok: true };
});

const setPhotoInput = z.object({
  driverId: z.string().min(1).max(64),
  storagePath: z.string().min(1).max(500),
});

/**
 * Points a chofer's `photoUrl` at a profile photo already uploaded to their
 * avatar folder — by the office for anyone, or by a chofer for themselves.
 *
 * The URL is minted here from the object rather than taken from the client, so
 * `photoUrl` can only ever name a file the Storage rules vetted as a small
 * image in this chofer's own folder. Earlier photos are deleted: nothing links
 * to them once this lands, and a face is not something to keep unasked.
 */
export const setDriverPhoto = onCall({ region, cors: true }, async (request) => {
  const parsed = setPhotoInput.safeParse(request.data);
  if (!parsed.success) throw invalidArgument('Datos de la foto inválidos.');

  const caller = requireAuth(request);
  const input = parsed.data;

  const isStaff = caller.role === UserRole.admin || caller.role === UserRole.ops;
  const isOwnRecord =
    caller.role === UserRole.driver && caller.uid === input.driverId;
  if (!isStaff && !isOwnRecord) throw permissionDenied();

  const folder = `drivers/${input.driverId}/avatar/`;
  if (!input.storagePath.startsWith(folder) || input.storagePath.includes('..')) {
    throw invalidArgument('La ruta de la foto no corresponde a este chofer.');
  }

  const driverRef = Paths.driver(input.driverId);
  const snap = await driverRef.get();
  if (!snap.exists) throw precondition(Code.notFound, 'Chofer no encontrado.');

  const bucket = getStorage().bucket();
  const file = bucket.file(input.storagePath);
  const [exists] = await file.exists();
  if (!exists) throw precondition(Code.notFound, 'La foto no se encontró.');

  const [metadata] = await file.getMetadata();
  if (!/^image\/(jpeg|png|webp)$/.test(String(metadata.contentType ?? ''))) {
    throw invalidArgument('La foto debe ser JPG, PNG o WEBP.');
  }

  const photoUrl = await getDownloadURL(file);
  await driverRef.update({ photoUrl, updatedAt: FieldValue.serverTimestamp() });

  const [previous] = await bucket.getFiles({ prefix: folder });
  await Promise.all(
    previous
      .filter((f) => f.name !== input.storagePath)
      .map((f) => f.delete().catch(() => undefined)),
  );

  await audit(caller.uid, 'setDriverPhoto', input.driverId);
  logger.info('driver.photoSet', { driverId: input.driverId });

  return { photoUrl };
});

/**
 * Activates, deactivates or suspends a chofer.
 *
 * Suspension is immediate and total: refresh tokens are revoked so an existing
 * session cannot keep working for the up-to-an-hour a claim stays valid, and
 * the RTDB node is switched off so dispatch stops seeing them.
 */
export const setDriverStatus = onCall({ region, cors: true }, async (request) => {
  const parsed = z
    .object({
      driverId: z.string().min(1).max(64),
      status: z.nativeEnum(DriverStatus),
      reason: z.string().max(300).default(''),
    })
    .safeParse(request.data);
  if (!parsed.success) throw invalidArgument('Datos inválidos.');

  const caller = requireAdmin(request);
  const { driverId, status, reason } = parsed.data;

  const snap = await Paths.driver(driverId).get();
  const driver = snap.data();
  if (!driver) throw precondition(Code.notFound, 'Chofer no encontrado.');
  // An archived chofer's Auth account is disabled; activating the record would
  // put a name on the roster that can never sign in.
  if (driver['archived'] === true) {
    throw precondition(Code.notFound, 'Este chofer fue eliminado.');
  }

  // Deactivating somebody mid-tow would strand a loaded vehicle.
  const busyWith = driver['currentServiceId'] as string | undefined;
  if (status !== DriverStatus.active && busyWith) {
    throw precondition(
      Code.driverBusy,
      'Este chofer tiene un servicio en curso. Reasígnalo primero.',
      { serviceId: busyWith },
    );
  }

  await Paths.driver(driverId).update({
    status,
    statusReason: reason,
    ...(status === DriverStatus.active ? {} : { isOnline: false }),
    updatedAt: FieldValue.serverTimestamp(),
  });

  if (status !== DriverStatus.active) {
    await Paths.live(driverId).update({ isOnline: false, updatedAt: Date.now() });
    await getAuth().revokeRefreshTokens(driverId);
  }

  await audit(caller.uid, 'setDriverStatus', driverId, { status, reason });
  logger.info('driver.statusSet', { driverId, status, by: caller.uid });
  return { ok: true };
});

const updateDriverInput = z.object({
  driverId: z.string().min(1).max(64),
  name: z.string().trim().min(3).max(120),
  phone: z.string().min(10).max(20),
  email: z.string().trim().email().max(200),
  licenseNumber: z.string().trim().max(40).default(''),
  licenseExpiry: z.string().datetime().nullish(),
  truckId: z.string().max(64).nullish(),
  zones: z.array(z.string().max(60)).max(20).default([]),
  companyName: z.string().trim().max(120).default(''),
  rnc: rncSchema,
});

/**
 * Saves the office's edits to a chofer.
 *
 * The cédula is not editable: it is who the chofer is, and the duplicate check
 * keys on it. Changing the grúa moves the assignment off the old truck and
 * onto the new one in the same batch, and is refused mid-tow — the customer's
 * screen would otherwise show a plate that is not the one arriving.
 */
export const updateDriver = onCall({ region, cors: true }, async (request) => {
  const parsed = updateDriverInput.safeParse(request.data);
  if (!parsed.success) throw invalidArgument('Revisa los datos del chofer.');

  const caller = requireAdmin(request);
  const input = parsed.data;

  const driverRef = Paths.driver(input.driverId);
  const driver = (await driverRef.get()).data();
  if (!driver || driver['archived'] === true) {
    throw precondition(Code.notFound, 'Chofer no encontrado.');
  }

  const previousTruckId =
    (driver['assignedTruckId'] as string | null | undefined) ?? null;
  const nextTruckId = input.truckId ?? null;
  const truckChanged = previousTruckId !== nextTruckId;

  const busyWith = driver['currentServiceId'] as string | undefined;
  if (truckChanged && busyWith) {
    throw precondition(
      Code.driverBusy,
      'Este chofer tiene un servicio en curso. Cambia la grúa cuando termine.',
      { serviceId: busyWith },
    );
  }

  let nextTruck: Record<string, unknown> | undefined;
  if (nextTruckId) {
    nextTruck = (await Paths.truck(nextTruckId).get()).data();
    if (!nextTruck) throw precondition(Code.notFound, 'Grúa no encontrada.');
    const holder = nextTruck['assignedDriverId'] as string | null | undefined;
    if (truckChanged && holder && holder !== input.driverId) {
      throw precondition(Code.invalidInput, 'Esa grúa ya está asignada a otro chofer.');
    }
  }

  // Auth first: it is the write that can refuse (an email already taken), and
  // nothing has been written yet when it does.
  try {
    await getAuth().updateUser(input.driverId, {
      email: input.email,
      displayName: input.name,
      ...(input.phone.startsWith('+') ? { phoneNumber: input.phone } : {}),
    });
  } catch (error) {
    const code = (error as { code?: string }).code ?? '';
    // A record with no Auth user behind it (an import, a seed) still takes
    // its edits; there is simply no credential to keep in step.
    if (code !== 'auth/user-not-found') {
      const message = signUpRefusals[code];
      if (message) throw precondition(Code.invalidInput, message);
      throw error;
    }
  }

  const now = FieldValue.serverTimestamp();
  const batch = db.batch();
  batch.update(driverRef, {
    name: input.name,
    phone: input.phone,
    email: input.email,
    licenseNumber: input.licenseNumber,
    licenseExpiry: input.licenseExpiry ? new Date(input.licenseExpiry) : null,
    zones: input.zones,
    companyName: input.companyName,
    rnc: input.rnc.replace(/\D/g, ''),
    ...(truckChanged
      ? {
          assignedTruckId: nextTruckId,
          assignedTruckPlate: (nextTruck?.['plate'] as string | undefined) ?? '',
          truckType: (nextTruck?.['type'] as string | undefined) || 'unknown',
        }
      : {}),
    // No grúa, no going online: taken offline rather than left dispatchable
    // with nothing to drive.
    ...(truckChanged && !nextTruckId ? { isOnline: false } : {}),
    updatedAt: now,
  });
  if (truckChanged && previousTruckId) {
    batch.update(Paths.truck(previousTruckId), {
      assignedDriverId: null,
      assignedDriverName: '',
      updatedAt: now,
    });
  }
  if (nextTruckId) {
    // Also when the grúa did not change, so a renamed chofer is renamed on it.
    batch.update(Paths.truck(nextTruckId), {
      assignedDriverId: input.driverId,
      assignedDriverName: input.name,
      updatedAt: now,
    });
  }
  await batch.commit();

  if (truckChanged && !nextTruckId) {
    await Paths.live(input.driverId)
      .update({ isOnline: false, updatedAt: Date.now() })
      .catch(() => undefined);
  }

  await audit(caller.uid, 'updateDriver', input.driverId, {
    email: input.email,
    truckChanged,
  });
  return { ok: true };
});

/**
 * Deletes a chofer for good: their login, their record, their papers and
 * photos, and their place on the live map. The email and the cédula are free
 * again the moment it returns.
 *
 * What stays is the company's own history — past services, cortes, earnings
 * and the audit trail. Those are the books, and they keep the chofer's name
 * as it was when the work was done.
 *
 * Refused mid-tow, like a deactivation, and while the chofer still holds cash
 * for the company: that money has to be collected in a corte first, or it
 * leaves the books with them. Safe to run twice; a chofer already gone is
 * cleaned up again rather than refused, which is also how the accounts
 * archived before deletion existed get removed.
 */
export const deleteDriver = onCall(
  { region, cors: true, timeoutSeconds: 120 },
  async (request) => {
    const parsed = z
      .object({ driverId: z.string().min(1).max(64) })
      .safeParse(request.data);
    if (!parsed.success) throw invalidArgument('Datos inválidos.');

    const caller = requireAdmin(request);
    const { driverId } = parsed.data;

    const driverRef = Paths.driver(driverId);
    const driver = (await driverRef.get()).data();

    if (driver) {
      const busyWith = driver['currentServiceId'] as string | undefined;
      if (busyWith) {
        throw precondition(
          Code.driverBusy,
          'Este chofer tiene un servicio en curso. Elimínalo cuando termine.',
          { serviceId: busyWith },
        );
      }
      const cash = Number(driver['cashOnHandCents'] ?? 0);
      if (cash > 0) {
        throw precondition(
          Code.invalidInput,
          'Este chofer tiene efectivo pendiente. Haz el corte antes de eliminarlo.',
          { cashOnHandCents: cash },
        );
      }

      const truckId = driver['assignedTruckId'] as string | null | undefined;
      if (truckId) {
        // The grúa goes back to the pool for the next chofer.
        const truck = await Paths.truck(truckId).get();
        if (truck.data()?.['assignedDriverId'] === driverId) {
          await Paths.truck(truckId).update({
            assignedDriverId: null,
            assignedDriverName: '',
            updatedAt: FieldValue.serverTimestamp(),
          });
        }
      }
    }

    // The record with its documents and push tokens, and a profile document
    // if one was ever made.
    await db.recursiveDelete(driverRef);
    await db.recursiveDelete(Paths.user(driverId));

    // Licence photos and the profile photo.
    await getStorage()
      .bucket()
      .deleteFiles({ prefix: `drivers/${driverId}/` })
      .catch((error: unknown) => {
        logger.warn('driver.deleteFilesFailed', { driverId, error: String(error) });
      });

    await Paths.live(driverId).remove().catch(() => undefined);
    await Paths.presence(driverId).remove().catch(() => undefined);

    await getAuth()
      .deleteUser(driverId)
      .catch((error: unknown) => {
        if ((error as { code?: string }).code !== 'auth/user-not-found') throw error;
      });

    // Who was deleted, by name only: the trail says what happened without
    // keeping the papers that were just removed.
    await audit(caller.uid, 'deleteDriver', driverId, {
      name: (driver?.['name'] as string | undefined) ?? '',
    });
    logger.info('driver.deleted', { driverId, by: caller.uid });
    return { ok: true };
  },
);

/**
 * A dispatcher assigns the job by hand.
 *
 * Used when the cascade gave up. The same invariants as an automatic accept
 * apply — the chofer must be active, free and driving the right truck — because
 * a manual assignment that ignores them produces the same stranded customer,
 * just later.
 */
export const assignServiceManually = onCall({ region, cors: true }, async (request) => {
  const parsed = z
    .object({
      serviceId: z.string().min(1).max(64),
      driverId: z.string().min(1).max(64),
      note: z.string().max(300).default(''),
    })
    .safeParse(request.data);
  if (!parsed.success) throw invalidArgument('Datos inválidos.');

  const caller = requireStaff(request);
  const { serviceId, driverId, note } = parsed.data;

  await applyTransition({
    serviceId,
    event: ServiceEventName.assignServiceManually,
    actorId: caller.uid,
    actorRole: caller.role as UserRole,
    meta: { driverId, note },

    inTransaction: async ({ transaction }) => {
      const driverRef = Paths.driver(driverId);
      const driverSnap = await transaction.get(driverRef);
      const driver = driverSnap.data();

      if (!driver) throw precondition(Code.notFound, 'Chofer no encontrado.');
      if (driver['status'] !== DriverStatus.active) {
        throw precondition(Code.driverInactive, 'Ese chofer no está activo.');
      }
      if (driver['currentServiceId']) {
        throw precondition(Code.driverBusy, 'Ese chofer ya tiene un servicio.');
      }

      transaction.update(driverRef, {
        currentServiceId: serviceId,
        updatedAt: FieldValue.serverTimestamp(),
      });

      transaction.update(Paths.service(serviceId), {
        driverId,
        driverName: driver['name'] ?? '',
        driverPhone: driver['phone'] ?? '',
        // Copied like an automatic accept copies it: without it the customer's
        // tracking card and chat showed a manually assigned chofer as a letter.
        driverPhotoUrl: driver['photoUrl'] ?? '',
        // What the customer reads: the plain average, 0 before any rating.
        driverRating: averageRating(
          (driver['ratingSum'] as number | undefined) ?? 0,
          (driver['ratingCount'] as number | undefined) ?? 0,
        ),
        truckId: driver['assignedTruckId'] ?? null,
        truckPlate: driver['assignedTruckPlate'] ?? '',
        assignedAt: FieldValue.serverTimestamp(),
        assignmentMode: AssignmentMode.manual,
        'timeline.acceptedAt': FieldValue.serverTimestamp(),
      });
    },

    afterCommit: async ({ service }) => {
      await Paths.live(driverId).update({
        state: DriverLiveState.onService,
        serviceId,
        updatedAt: Date.now(),
      });

      // Pushed as an assignment, not an offer: there is nothing to accept or
      // decline, so a ringing screen with two buttons would be a lie.
      await notify({
        uid: driverId,
        audience: 'driver',
        title: 'Servicio asignado',
        body: 'La oficina te asignó un servicio.',
        data: { serviceId, type: 'assigned' },
      });

      const clientId = service['clientId'] as string | undefined;
      if (clientId) {
        await notify({
          uid: clientId,
          audience: 'client',
          title: 'Tu grúa va en camino',
          body: 'Ya asignamos un chofer a tu servicio.',
          data: { serviceId, type: 'driver_assigned' },
        });
      }
    },
  });

  await audit(caller.uid, 'assignServiceManually', serviceId, { driverId, note });
  return { ok: true };
});

/**
 * The operator's go-ahead on a heavy job.
 *
 * A camión, patana or equipo pesado is only ever quoted an estimate. The
 * operator talks to the customer, makes sure a heavy grúa can do it, and
 * enters the price they agreed — what the customer pays, ITBIS included when
 * there is any. Only then does the job look for a grúa: dispatch starts
 * straight away, and the office can still assign one by hand.
 */
export const confirmHeavyService = onCall({ region, cors: true }, async (request) => {
  const parsed = z
    .object({
      serviceId: z.string().min(1).max(64),
      // RD$100 to RD$1,000,000: a typo of two zeros either way is refused.
      totalCents: z.number().int().min(10000).max(100000000),
      note: z.string().max(300).default(''),
    })
    .safeParse(request.data);
  if (!parsed.success) throw invalidArgument('Revisa el precio e intenta de nuevo.');

  const caller = requireStaff(request);
  const { serviceId, totalCents, note } = parsed.data;
  let estimatedCents = 0;

  await applyTransition({
    serviceId,
    event: ServiceEventName.confirmHeavyService,
    actorId: caller.uid,
    actorRole: caller.role as UserRole,
    meta: { totalCents, note },

    inTransaction: ({ service, transaction }) => {
      const quote = service['quote'] as Quote;
      estimatedCents = quote.totalCents;
      transaction.update(Paths.service(serviceId), {
        quote: confirmedQuote(quote, totalCents),
        'operatorReview.state': OperatorReviewState.confirmed,
        'operatorReview.confirmedTotalCents': totalCents,
        'operatorReview.confirmedBy': caller.uid,
        'operatorReview.confirmedAt': FieldValue.serverTimestamp(),
        'operatorReview.note': note,
        'dispatch.lastReason': '',
      });
    },

    afterCommit: async ({ service }) => {
      const clientId = service['clientId'] as string | undefined;
      if (clientId) {
        await notify({
          uid: clientId,
          audience: 'client',
          title: 'Servicio confirmado',
          body: 'Confirmamos tu grúa especial y el precio. Ya estamos buscando la grúa.',
          data: { serviceId, type: 'heavy_confirmed' },
        });
      }
      await dispatchNext(serviceId);
    },
  });

  await audit(caller.uid, 'confirmHeavyService', serviceId, {
    estimatedCents,
    totalCents,
    note,
  });
  return { ok: true };
});

/**
 * Grants the first admin.
 *
 * Succeeds only when nobody holds an admin claim yet and the caller's email is
 * on the allowlist, so this cannot be used to escalate later. After the first
 * admin exists it is permanently inert.
 */
export const bootstrapFirstAdmin = onCall({ region, cors: true }, async (request) => {
  const caller = requireAuth(request);

  const allowlist = (process.env['ADMIN_BOOTSTRAP_EMAILS'] ?? '')
    .split(',')
    .map((entry) => entry.trim().toLowerCase())
    .filter(Boolean);

  const email = (request.auth?.token['email'] as string | undefined)?.toLowerCase();
  if (!email || !allowlist.includes(email)) throw permissionDenied();

  const existing = await db.collection('admins_marker').doc('bootstrapped').get();
  if (existing.exists) {
    throw precondition(Code.invalidInput, 'Ya existe un administrador.');
  }

  await getAuth().setCustomUserClaims(caller.uid, { role: UserRole.admin });
  await db.collection('admins_marker').doc('bootstrapped').set({
    uid: caller.uid,
    at: FieldValue.serverTimestamp(),
  });

  await audit(caller.uid, 'bootstrapFirstAdmin', caller.uid, { email });
  logger.warn('admin.bootstrapped', { uid: caller.uid, email });

  return { ok: true, role: UserRole.admin };
});

/** Sets or clears a staff role. Refuses to remove the last admin. */
export const setAdminRole = onCall({ region, cors: true }, async (request) => {
  const parsed = z
    .object({
      uid: z.string().min(1).max(128),
      role: z.enum([UserRole.admin, UserRole.ops]).nullable(),
    })
    .safeParse(request.data);
  if (!parsed.success) throw invalidArgument('Datos inválidos.');

  const caller = requireAdmin(request);
  const { uid, role } = parsed.data;

  if (role === null && uid === caller.uid) {
    throw precondition(
      Code.invalidInput,
      'No puedes quitarte tu propio acceso de administrador.',
    );
  }

  // A person of an insurance company is fenced to that company by their
  // claims. Overwriting them here would turn a customer's employee into
  // office staff, so that account has to be dealt with deliberately instead.
  const target = await getAuth().getUser(uid);
  if (target.customClaims?.['role'] === UserRole.insurer) {
    throw precondition(
      Code.invalidInput,
      'Esta cuenta pertenece a una aseguradora. Gestiónala desde Aseguradoras.',
    );
  }

  await getAuth().setCustomUserClaims(uid, role ? { role } : {});
  await getAuth().revokeRefreshTokens(uid);
  await audit(caller.uid, 'setAdminRole', uid, { role });

  return { ok: true };
});

/** What the caller is allowed to do. The panel's single source of truth. */
export const whoAmI = onCall({ region, cors: true }, async (request) => {
  const caller = requireAuth(request);
  return {
    uid: caller.uid,
    role: caller.role ?? null,
    canManageDrivers: caller.role === UserRole.admin,
    canAssignServices:
      caller.role === UserRole.admin || caller.role === UserRole.ops,
    canEditPricing: caller.role === UserRole.admin,
    canManageInsurers: caller.role === UserRole.admin,
    insurerId: caller.insurerId ?? null,
    insurerRole: caller.insurerRole ?? null,
  };
});
