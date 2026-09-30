import { ACTIVE_STATUSES, type ServiceStatus } from './enums.js';

/** How many vehicle photos a request may carry — the form allows three. */
export const MAX_VEHICLE_PHOTOS = 3;

/**
 * Whether a vehicle photo on a request is one of ours: a download URL from the
 * project's own bucket.
 *
 * The chofer's app loads these as they are, so a request must not be able to
 * point it at any address on the internet.
 */
export function isVehiclePhotoUrl(value: string): boolean {
  let url: URL;
  try {
    url = new URL(value);
  } catch {
    return false;
  }
  if (url.protocol === 'https:') {
    return (
      url.hostname === 'firebasestorage.googleapis.com' ||
      url.hostname.endsWith('.firebasestorage.app')
    );
  }
  // The Storage emulator, and only when running under the emulator.
  return (
    process.env['FUNCTIONS_EMULATOR'] === 'true' &&
    url.protocol === 'http:' &&
    (url.hostname === 'localhost' || url.hostname === '127.0.0.1')
  );
}

/** How many proof photos one transition may carry — the chofer's sheet allows six. */
export const MAX_PROOF_PHOTOS = 6;

/**
 * Whether [path] is one of the chofer's proof photos for this service: a file
 * directly under `service_photos/{serviceId}/`, where storage.rules lets only
 * the assigned chofer write.
 *
 * Without it a chofer could file another job's photos — or any string — as the
 * record of this vehicle's condition.
 */
export function isProofPhotoPath(serviceId: string, path: string): boolean {
  const prefix = `service_photos/${serviceId}/`;
  if (!path.startsWith(prefix)) return false;
  const name = path.slice(prefix.length);
  return /^[A-Za-z0-9_.-]+$/.test(name) && !name.includes('..');
}

/**
 * The vehicle photos to copy onto an offer: only well-formed ones, at most
 * [MAX_VEHICLE_PHOTOS].
 */
export function vehiclePhotoUrls(vehicle: unknown): string[] {
  const photos = ((vehicle ?? {}) as Record<string, unknown>)['photoPaths'];
  if (!Array.isArray(photos)) return [];
  return photos
    .filter((p): p is string => typeof p === 'string' && isVehiclePhotoUrl(p))
    .slice(0, MAX_VEHICLE_PHOTOS);
}

/**
 * Whether a service has a chofer on it but no photo of them.
 *
 * True for services assigned by hand before `assignServiceManually` copied the
 * photo across, and for a chofer who added their photo after taking the job.
 * Only while the service is active: a finished tow's customer is not looking
 * at the card any more, and there is no reason to rewrite history.
 */
export function needsServiceDriverPhoto(service: {
  status?: unknown;
  driverId?: unknown;
  driverPhotoUrl?: unknown;
}): boolean {
  return (
    ACTIVE_STATUSES.includes(service.status as ServiceStatus) &&
    typeof service.driverId === 'string' &&
    service.driverId.length > 0 &&
    !(typeof service.driverPhotoUrl === 'string' && service.driverPhotoUrl.length > 0)
  );
}
