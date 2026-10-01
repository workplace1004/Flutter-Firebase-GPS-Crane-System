import { describe, expect, it } from 'vitest';

import {
  applyClientRating,
  applyRating,
  clientTagsFor,
  needsClientReview,
  averageRating,
  dispatchRating,
  needsReview,
  PRIOR_RATING,
  RECENT_FEEDBACK_LIMIT,
  tagsFor,
  withinRatingWindow,
} from '../src/lib/driverRating.js';

/** A customer's rating of the chofer, and what it does to their record. */
describe('driver rating', () => {
  it('keeps praise with a good rating and complaints with a poor one', () => {
    expect(tagsFor(5, ['punctual', 'late', 'careful'])).toEqual(['punctual', 'careful']);
    expect(tagsFor(2, ['punctual', 'late', 'vehicle_damage'])).toEqual([
      'late',
      'vehicle_damage',
    ]);
    // Three stars is a complaint: the chofer did something to lose two.
    expect(tagsFor(3, ['courteous', 'rude'])).toEqual(['rude']);
  });

  it('drops unknown and repeated tags instead of refusing the rating', () => {
    expect(tagsFor(5, ['punctual', 'punctual', 'retired_tag'])).toEqual(['punctual']);
  });

  it('sends low stars and serious complaints to the office', () => {
    expect(needsReview(1, [])).toBe(true);
    expect(needsReview(2, [])).toBe(true);
    expect(needsReview(3, [])).toBe(false);
    expect(needsReview(3, ['late'])).toBe(false);
    // However many stars: damage, overcharging, danger and rudeness are looked at.
    expect(needsReview(3, ['vehicle_damage'])).toBe(true);
    expect(needsReview(3, ['overcharge'])).toBe(true);
    expect(needsReview(3, ['unsafe_driving'])).toBe(true);
    expect(needsReview(3, ['rude'])).toBe(true);
    expect(needsReview(5, [])).toBe(false);
  });

  it('starts a new chofer at the prior, and one bad rating does not sink them', () => {
    expect(dispatchRating(0, 0)).toBe(PRIOR_RATING);
    // (1 + 4.8 × 5) / 6
    expect(dispatchRating(1, 1)).toBe(4.17);
    // A long record is ranked on itself.
    expect(dispatchRating(4.2 * 500, 500)).toBeCloseTo(4.21, 2);
  });

  it('shows the plain average, and nothing before the first rating', () => {
    expect(averageRating(0, 0)).toBe(0);
    expect(averageRating(14, 3)).toBe(4.7);
  });

  it('folds a rating into the summary', () => {
    const once = applyRating({}, { stars: 5, tags: ['punctual'], comment: 'Excelente' });
    expect(once).toMatchObject({
      ratingSum: 5,
      ratingCount: 1,
      ratingStars: { '5': 1 },
      ratingTags: { punctual: 1 },
    });

    const twice = applyRating(once, { stars: 2, tags: ['late'], comment: '' });
    expect(twice.ratingSum).toBe(7);
    expect(twice.ratingCount).toBe(2);
    expect(twice.ratingStars).toEqual({ '5': 1, '2': 1 });
    expect(twice.ratingTags).toEqual({ punctual: 1, late: 1 });
    expect(twice.rating).toBe(dispatchRating(7, 2));
    // Newest first, and nothing that names the service or the customer.
    expect(twice.recentFeedback[0]).toEqual({ stars: 2, tags: ['late'], comment: '' });
    expect(Object.keys(twice.recentFeedback[1]!)).toEqual(['stars', 'tags', 'comment']);
  });

  it('keeps only the latest feedback for the chofer to read', () => {
    let summary = applyRating({}, { stars: 5, tags: [], comment: 'primero' });
    for (let i = 0; i < RECENT_FEEDBACK_LIMIT + 3; i++) {
      summary = applyRating(summary, { stars: 4, tags: [], comment: `${i}` });
    }
    expect(summary.recentFeedback).toHaveLength(RECENT_FEEDBACK_LIMIT);
    expect(summary.recentFeedback.some((f) => f.comment === 'primero')).toBe(false);
  });

  it('can be rated for a week after the tow', () => {
    const finished = new Date('2026-09-01T12:00:00Z');
    expect(withinRatingWindow(finished, new Date('2026-09-08T12:00:00Z'))).toBe(true);
    expect(withinRatingWindow(finished, new Date('2026-09-08T12:00:01Z'))).toBe(false);
    expect(withinRatingWindow(undefined, new Date())).toBe(true);
  });
});

/** A chofer's rating of the customer, and what it does to their record. */
describe('client rating', () => {
  it('keeps only customer tags that fit the stars', () => {
    // "punctual" is praise for a chofer, not something a customer is.
    expect(clientTagsFor(5, ['ready', 'punctual', 'not_there'])).toEqual(['ready']);
    expect(clientTagsFor(1, ['ready', 'payment_problem', 'rude'])).toEqual([
      'payment_problem',
      'rude',
    ]);
  });

  it('tells the office about rudeness and refusals to pay', () => {
    expect(needsClientReview(4, [])).toBe(false);
    expect(needsClientReview(3, ['not_there'])).toBe(false);
    expect(needsClientReview(3, ['payment_problem'])).toBe(true);
    expect(needsClientReview(2, [])).toBe(true);
  });

  it("folds into the customer's record", () => {
    const once = applyClientRating({}, 5, ['ready']);
    const twice = applyClientRating(once, 2, ['not_there']);
    expect(twice).toEqual({
      ratingSum: 7,
      ratingCount: 2,
      ratingTags: { ready: 1, not_there: 1 },
    });
  });
});
