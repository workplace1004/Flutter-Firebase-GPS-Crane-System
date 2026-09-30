import { describe, expect, it } from 'vitest';

import {
  isProofPhotoPath,
  isVehiclePhotoUrl,
  needsServiceDriverPhoto,
  vehiclePhotoUrls,
} from '../src/lib/servicePhoto.js';

const BUCKET_URL =
  'https://firebasestorage.googleapis.com/v0/b/gruasrd-ce2ae.firebasestorage.app/o/requests%2Fu1%2F1.jpg?alt=media&token=abc';

/**
 * The photos a customer adds to a request, which the chofer's app loads as-is.
 */
describe('vehicle photos', () => {
  it("accepts a download URL from the project's bucket", () => {
    expect(isVehiclePhotoUrl(BUCKET_URL)).toBe(true);
    expect(
      isVehiclePhotoUrl('https://gruasrd-ce2ae.firebasestorage.app/requests/u1/1.jpg'),
    ).toBe(true);
  });

  it('refuses anything else, so a request cannot point the chofer anywhere', () => {
    expect(isVehiclePhotoUrl('https://example.com/car.jpg')).toBe(false);
    expect(isVehiclePhotoUrl('http://firebasestorage.googleapis.com/x.jpg')).toBe(false);
    expect(isVehiclePhotoUrl('file:///sdcard/DCIM/car.jpg')).toBe(false);
    expect(isVehiclePhotoUrl('blob:http://localhost/1234')).toBe(false);
    expect(isVehiclePhotoUrl('not a url')).toBe(false);
  });

  it('copies only valid photos onto the offer, three at most', () => {
    expect(
      vehiclePhotoUrls({
        photoPaths: [BUCKET_URL, 'https://example.com/x.jpg', BUCKET_URL, BUCKET_URL, BUCKET_URL],
      }),
    ).toEqual([BUCKET_URL, BUCKET_URL, BUCKET_URL]);
    expect(vehiclePhotoUrls({})).toEqual([]);
    expect(vehiclePhotoUrls(undefined)).toEqual([]);
  });
});

/**
 * Which services get their chofer's photo filled in.
 *
 * Assigning by hand used to leave the photo off the service, so the customer's
 * tracking card and chat showed the chofer as a single letter.
 */
describe('needsServiceDriverPhoto', () => {
  it('fills in an active service with a chofer and no photo', () => {
    for (const status of ['accepted', 'arrived', 'in_progress']) {
      expect(needsServiceDriverPhoto({ status, driverId: 'driver-1' })).toBe(true);
      expect(needsServiceDriverPhoto({ status, driverId: 'driver-1', driverPhotoUrl: '' })).toBe(true);
    }
  });

  it('leaves a service that already has the photo alone, so it cannot loop', () => {
    expect(
      needsServiceDriverPhoto({
        status: 'arrived',
        driverId: 'driver-1',
        driverPhotoUrl: 'https://example.com/p.jpg',
      }),
    ).toBe(false);
  });

  it('ignores a service nobody has taken yet', () => {
    expect(needsServiceDriverPhoto({ status: 'pending_dispatch' })).toBe(false);
    expect(needsServiceDriverPhoto({ status: 'pending_dispatch', driverId: '' })).toBe(false);
  });

  it('does not rewrite finished tows', () => {
    expect(needsServiceDriverPhoto({ status: 'closed', driverId: 'driver-1' })).toBe(false);
    expect(needsServiceDriverPhoto({ status: 'cancelled', driverId: 'driver-1' })).toBe(false);
  });
});

/**
 * The chofer's photos at pickup and drop-off, filed on the service as the
 * record of the vehicle's condition.
 */
describe('proof photos', () => {
  it("accepts a file in the service's own folder", () => {
    expect(isProofPhotoPath('s1', 'service_photos/s1/pickup_1727700000000.jpg')).toBe(true);
  });

  it("refuses another service's folder, a sub-folder and a way out", () => {
    expect(isProofPhotoPath('s1', 'service_photos/s2/pickup_1.jpg')).toBe(false);
    expect(isProofPhotoPath('s1', 'service_photos/s1/x/pickup_1.jpg')).toBe(false);
    expect(isProofPhotoPath('s1', 'service_photos/s1/../s2/pickup_1.jpg')).toBe(false);
    expect(isProofPhotoPath('s1', 'service_photos/s1/')).toBe(false);
  });

  it('refuses the placeholder names the app used to send', () => {
    expect(isProofPhotoPath('s1', 'demo-pickup-1')).toBe(false);
    expect(isProofPhotoPath('s1', BUCKET_URL)).toBe(false);
  });
});
