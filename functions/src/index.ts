import { setGlobalOptions } from 'firebase-functions/v2';
import { onTaskDispatched } from 'firebase-functions/v2/tasks';
import { logger } from 'firebase-functions/v2';
import { getStorage } from 'firebase-admin/storage';
import { onCall } from 'firebase-functions/v2/https';
import { z } from 'zod';

import { expireOffer as runExpireOffer } from './dispatch/offers.js';
import { Code, invalidArgument, precondition } from './lib/errors.js';
import { Paths, StoragePaths } from './lib/firestore.js';
import { requireAuth } from './lib/guards.js';
import { UserRole } from './lib/enums.js';
import { region } from './callables/region.js';

/**
 * Every function the project deploys.
 *
 * Kept flat and explicit: Firebase discovers functions by walking this module's
 * exports, so a function that is not re-exported here silently does not exist.
 */

setGlobalOptions({
  region,
  // A tow company's traffic is bursty rather than large. A low ceiling keeps a
  // runaway loop from becoming a runaway bill, and is trivially raised.
  maxInstances: 20,
  memory: '256MiB',
  timeoutSeconds: 60,
});

// ---------------------------------------------------------------------------
// Callables — the contract the apps already call
// ---------------------------------------------------------------------------

export { quoteService, requestService } from './callables/request.js';
export { quoteInsurerService, createInsurerService } from './callables/insurerServices.js';
export { nearbyTrucks } from './callables/nearby.js';
export {
  requestChat,
  respondChatRequest,
  closeChatRequest,
} from './callables/chatRequests.js';
export { answerCall, endCall, startCall } from './callables/calls.js';
export { ensureProfile } from './callables/profile.js';
export { rateService, resolveDriverReview, publishEta } from './callables/feedback.js';
export {
  setOnline,
  acceptService,
  rejectService,
  markArrived,
  startService,
  completeService,
  confirmCashCollected,
  cancelService,
  cancelByDriver,
} from './callables/lifecycle.js';
export {
  createDriver,
  registerDriver,
  attachDriverDocument,
  setDriverPhoto,
  setDriverStatus,
  updateDriver,
  deleteDriver,
  assignServiceManually,
  confirmHeavyService,
  bootstrapFirstAdmin,
  setAdminRole,
  whoAmI,
} from './callables/admin.js';
export {
  verifyDriverLicense,
  reviewLicenseVerification,
  correctDriverRegistration,
} from './callables/licenseVerification.js';
export { createTruck, updateTruck, archiveTruck } from './callables/trucks.js';
export {
  createInsurer,
  updateInsurer,
  createInsurerUser,
  updateInsurerUser,
  insurerPasswordChanged,
} from './callables/insurers.js';
export { savePricingTable, resetPricingTable } from './callables/pricing.js';
export { settleDriverCash } from './callables/payments.js';
export {
  generateDriverSettlements,
  settleDriverSettlement,
  voidDriverSettlement,
  weeklyDriverSettlements,
} from './callables/settlements.js';
export {
  generateInsurerInvoices,
  markInsurerInvoicePaid,
  monthlyInsurerInvoices,
  voidInsurerInvoice,
} from './callables/insurerInvoices.js';
export { saveFiscalIssuer, saveNcfSequence } from './callables/fiscal.js';

// ---------------------------------------------------------------------------
// Triggers and scheduled work
// ---------------------------------------------------------------------------

export {
  followAppPresence,
  mirrorLivePosition,
  recordEarnings,
  notifyOnMessage,
  notifyOnChatRequestMessage,
  backfillChatRequestPhoto,
  backfillServiceDriverPhoto,
} from './triggers/index.js';

export {
  sweepExpiredOffers,
  reapStaleDrivers,
  releaseFinishedDrivers,
  expireAbandonedServices,
  tidyOrphanedOffers,
  closeFinishedInsurerTows,
} from './scheduled/index.js';

// ---------------------------------------------------------------------------
// Task queue
// ---------------------------------------------------------------------------

/**
 * Expires one offer at a precise instant.
 *
 * The queue name must match `Queues.expireOffer` in `lib/tasks.ts`, and the
 * export name is what Cloud Tasks addresses — renaming this export without
 * renaming the queue silently stops every offer from expiring on time, leaving
 * the sweeper to catch them a minute late.
 */
export const expireOffer = onTaskDispatched(
  {
    region,
    retryConfig: { maxAttempts: 3, minBackoffSeconds: 5 },
    rateLimits: { maxConcurrentDispatches: 20 },
  },
  async (request) => {
    const payload = request.data as { serviceId?: string; driverId?: string };
    if (!payload.serviceId) return;

    await runExpireOffer({
      serviceId: payload.serviceId,
      driverId: payload.driverId ?? '',
    });
  },
);

// ---------------------------------------------------------------------------
// Signed URLs
// ---------------------------------------------------------------------------

/**
 * Hands out a short-lived link to an invoice PDF.
 *
 * Storage refuses direct client reads of `invoices/`, so this is the only way
 * in. Fifteen minutes is long enough to open the file and short enough that a
 * link pasted into a group chat stops working.
 */
export const invoiceDownloadUrl = onCall({ region, cors: true }, async (request) => {
  const parsed = z
    .object({ invoiceId: z.string().min(1).max(64) })
    .safeParse(request.data);
  if (!parsed.success) throw invalidArgument('Factura inválida.');

  const caller = requireAuth(request);
  const { invoiceId } = parsed.data;

  const snap = await Paths.invoice(invoiceId).get();
  const invoice = snap.data();
  if (!invoice) throw precondition(Code.notFound, 'Factura no encontrada.');

  const isOwner = invoice['clientId'] === caller.uid;
  const isStaff = caller.role === UserRole.admin || caller.role === UserRole.ops;
  if (!isOwner && !isStaff) {
    throw precondition(Code.notFound, 'Factura no encontrada.');
  }

  const path = (invoice['pdfPath'] as string | undefined) ?? StoragePaths.invoicePdf(invoiceId);
  const file = getStorage().bucket().file(path);

  const [exists] = await file.exists();
  if (!exists) {
    throw precondition(Code.notFound, 'La factura todavía no está lista.');
  }

  const [url] = await file.getSignedUrl({
    action: 'read',
    expires: Date.now() + 15 * 60 * 1000,
  });

  logger.info('invoice.urlIssued', { invoiceId, uid: caller.uid });
  return { url };
});
