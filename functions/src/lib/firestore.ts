import { getApps, initializeApp } from 'firebase-admin/app';
import { FieldValue, GeoPoint, Timestamp, getFirestore } from 'firebase-admin/firestore';
import { getDatabase } from 'firebase-admin/database';

/**
 * Admin SDK access and typed paths.
 *
 * Every collection name in the backend appears here and nowhere else, matching
 * `packages/grua_core/lib/src/data/paths.dart`. A typo in `'sevices'` is a
 * silent empty result that looks like a permissions problem for an afternoon.
 */

// Functions can cold-start more than once per instance; initializing twice
// throws.
if (getApps().length === 0) initializeApp();

export const db = getFirestore();
export { FieldValue, GeoPoint, Timestamp };

/**
 * The Realtime Database, connected on first use.
 *
 * `getDatabase()` throws when it cannot determine a database URL, and doing
 * that at module load means importing a path helper — or a pure pricing
 * function two imports away — fails on any machine without live Firebase
 * config. Connecting lazily keeps the logic tests runnable with no emulator.
 */
let cachedRtdb: ReturnType<typeof getDatabase> | undefined;

export function rtdb(): ReturnType<typeof getDatabase> {
  cachedRtdb ??= getDatabase();
  return cachedRtdb;
}

/** Builds a Firestore GeoPoint from the plain shape the geo helpers use. */
export const GeoPointOf = (point: { latitude: number; longitude: number }): GeoPoint =>
  new GeoPoint(point.latitude, point.longitude);

export const Collections = {
  users: 'users',
  drivers: 'drivers',
  trucks: 'trucks',
  trucksByPlate: 'trucks_by_plate',
  services: 'services',
  tracking: 'tracking',
  invoices: 'invoices',
  earnings: 'earnings',
  config: 'config',
  reports: 'reports',
  audit: 'audit',
  chatRequests: 'chatRequests',
  calls: 'calls',
  cashSettlements: 'cashSettlements',
  insurers: 'insurers',
  pricingRules: 'pricingRules',
  driverSettlements: 'driverSettlements',
  insurerInvoices: 'insurerInvoices',
  fiscal: 'fiscal',
  ncfRegistry: 'ncfRegistry',
  driverReviews: 'driverReviews',
} as const;

export const Sub = {
  offers: 'offers',
  messages: 'messages',
  events: 'events',
  documents: 'documents',
  entries: 'entries',
  tokens: 'tokens',
  notifications: 'notifications',
  members: 'members',
  internal: 'internal',
} as const;

export const Paths = {
  user: (uid: string) => db.collection(Collections.users).doc(uid),
  userTokens: (uid: string) =>
    db.collection(Collections.users).doc(uid).collection(Sub.tokens),
  userNotifications: (uid: string) =>
    db.collection(Collections.users).doc(uid).collection(Sub.notifications),

  drivers: () => db.collection(Collections.drivers),
  driver: (uid: string) => db.collection(Collections.drivers).doc(uid),
  driverReviews: () => db.collection(Collections.driverReviews),
  /** One per rated service, keyed by the service: a service is rated once. */
  driverReview: (serviceId: string) =>
    db.collection(Collections.driverReviews).doc(serviceId),
  driverTokens: (uid: string) =>
    db.collection(Collections.drivers).doc(uid).collection(Sub.tokens),
  driverDocuments: (uid: string) =>
    db.collection(Collections.drivers).doc(uid).collection(Sub.documents),

  trucks: () => db.collection(Collections.trucks),
  truck: (id: string) => db.collection(Collections.trucks).doc(id),
  truckByPlate: (plate: string) =>
    db.collection(Collections.trucksByPlate).doc(plate.toUpperCase()),

  services: () => db.collection(Collections.services),
  service: (id: string) => db.collection(Collections.services).doc(id),
  offers: (serviceId: string) =>
    db.collection(Collections.services).doc(serviceId).collection(Sub.offers),
  offer: (serviceId: string, driverId: string) =>
    db
      .collection(Collections.services)
      .doc(serviceId)
      .collection(Sub.offers)
      .doc(driverId),
  events: (serviceId: string) =>
    db.collection(Collections.services).doc(serviceId).collection(Sub.events),
  messages: (serviceId: string) =>
    db.collection(Collections.services).doc(serviceId).collection(Sub.messages),
  /**
   * What an insurer's tow pays the chofer and keeps for the company. Kept off
   * the service document because the insurance company can read that one.
   */
  serviceBilling: (serviceId: string) =>
    db
      .collection(Collections.services)
      .doc(serviceId)
      .collection(Sub.internal)
      .doc('billing'),

  chatRequests: () => db.collection(Collections.chatRequests),
  chatRequest: (id: string) => db.collection(Collections.chatRequests).doc(id),
  calls: () => db.collection(Collections.calls),
  call: (id: string) => db.collection(Collections.calls).doc(id),
  chatRequestMessages: (id: string) =>
    db.collection(Collections.chatRequests).doc(id).collection(Sub.messages),

  tracking: (serviceId: string) =>
    db.collection(Collections.tracking).doc(serviceId),

  invoice: (id: string) => db.collection(Collections.invoices).doc(id),
  earnings: (driverId: string) =>
    db.collection(Collections.earnings).doc(driverId),
  earningEntries: (driverId: string) =>
    db.collection(Collections.earnings).doc(driverId).collection(Sub.entries),
  earningEntry: (driverId: string, serviceId: string) =>
    db
      .collection(Collections.earnings)
      .doc(driverId)
      .collection(Sub.entries)
      .doc(serviceId),

  pricingConfig: () => db.collection(Collections.config).doc('pricing'),
  dispatchConfig: () => db.collection(Collections.config).doc('dispatch'),
  appSettings: () => db.collection(Collections.config).doc('app'),
  ncfConfig: () => db.collection(Collections.config).doc('ncf'),
  /** `startAt`: jobs finished before it are left out of weekly cortes. */
  settlementsConfig: () => db.collection(Collections.config).doc('settlements'),

  /** Weekly cortes. See `lib/settlements.ts`. */
  driverSettlements: () => db.collection(Collections.driverSettlements),
  driverSettlement: (id: string) => db.collection(Collections.driverSettlements).doc(id),

  audit: () => db.collection(Collections.audit),
  cashSettlements: () => db.collection(Collections.cashSettlements),

  /** Monthly invoices to insurance companies. See `lib/insurerInvoice.ts`. */
  insurerInvoices: () => db.collection(Collections.insurerInvoices),
  insurerInvoice: (id: string) => db.collection(Collections.insurerInvoices).doc(id),
  /** The company that issues receipts. See `lib/fiscal.ts`. */
  fiscalIssuer: () => db.collection(Collections.fiscal).doc('issuer'),
  /** The NCF range a kind of receipt is numbered from. */
  ncfSequence: (prefix: string) => db.collection(Collections.fiscal).doc(`ncf_${prefix}`),
  /** One document per NCF ever issued, so none is issued twice. */
  ncfRegistry: (key: string) => db.collection(Collections.ncfRegistry).doc(key),

  /** Zone prices for insurance companies. See `lib/zonePricing.ts`. */
  pricingRules: () => db.collection(Collections.pricingRules),

  insurers: () => db.collection(Collections.insurers),
  insurer: (id: string) => db.collection(Collections.insurers).doc(id),
  /** The company's people, keyed by their Auth uid. */
  insurerMembers: (insurerId: string) =>
    db.collection(Collections.insurers).doc(insurerId).collection(Sub.members),
  insurerMember: (insurerId: string, uid: string) =>
    db
      .collection(Collections.insurers)
      .doc(insurerId)
      .collection(Sub.members)
      .doc(uid),

  live: (driverId: string) => rtdb().ref(`live/${driverId}`),
  liveRoot: () => rtdb().ref('live'),
  /** Whether the chofer's app is open; written by the app, cleared by onDisconnect. */
  presence: (driverId: string) => rtdb().ref(`presence/${driverId}`),
} as const;

/** Storage object paths. Storage is addressed by string, not by reference. */
export const StoragePaths = {
  invoicePdf: (invoiceId: string) => `invoices/${invoiceId}.pdf`,
  servicePhoto: (serviceId: string, name: string) =>
    `service_photos/${serviceId}/${name}`,
  driverDoc: (uid: string, docType: string, ext: string) =>
    `drivers/${uid}/docs/${docType}_${Date.now()}.${ext}`,
} as const;
