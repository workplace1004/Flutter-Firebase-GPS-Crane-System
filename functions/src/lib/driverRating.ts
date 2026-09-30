/**
 * A customer's evaluation of the chofer who towed their vehicle, and the
 * running summary it feeds on the chofer's record.
 *
 * Mirrored in `packages/grua_core/lib/src/domain/enums.dart`
 * (`DriverRatingTag`) and `driver_scorecard.dart`.
 */

/** What went well. Offered with four or five stars. */
export const POSITIVE_TAGS = [
  'punctual',
  'courteous',
  'careful',
  'professional',
  'good_truck',
] as const;

/** What went wrong. Offered with three stars or fewer. */
export const NEGATIVE_TAGS = [
  'late',
  'rude',
  'vehicle_damage',
  'overcharge',
  'unsafe_driving',
] as const;

export type DriverRatingTag = (typeof POSITIVE_TAGS)[number] | (typeof NEGATIVE_TAGS)[number];

export const ALL_TAGS: readonly DriverRatingTag[] = [...POSITIVE_TAGS, ...NEGATIVE_TAGS];

/**
 * Tags serious enough that the office must look, whatever the stars: damage to
 * the vehicle, asking for more money than the app quoted, dangerous driving.
 */
export const SERIOUS_TAGS: readonly DriverRatingTag[] = [
  'vehicle_damage',
  'overcharge',
  'unsafe_driving',
  'rude',
];

/** A tow can be rated for this long after it finished. */
export const RATING_WINDOW_DAYS = 7;

/** How many recent reviews the chofer's own record keeps for them to read. */
export const RECENT_FEEDBACK_LIMIT = 10;

/**
 * The dispatch score starts every chofer at [PRIOR_RATING], as if they had
 * [PRIOR_WEIGHT] ratings of it already. One bad rating on a new chofer then
 * moves them a little rather than to the bottom of the list, and a chofer
 * with hundreds of ratings is ranked on their own record.
 *
 * 4.8 is what every account has been opened with, so existing choferes with
 * no ratings keep the score they have.
 */
export const PRIOR_RATING = 4.8;
export const PRIOR_WEIGHT = 5;

/** Whether the office should review this rating. */
export function needsReview(stars: number, tags: readonly string[]): boolean {
  return stars <= 2 || tags.some((t) => (SERIOUS_TAGS as readonly string[]).includes(t));
}

/**
 * The tags a rating may carry for its stars: praise with a good rating,
 * complaints with a poor one. Unknown and duplicate tags are dropped rather
 * than refused, so an older app sending a retired tag can still rate.
 */
export function tagsFor(stars: number, tags: readonly string[]): DriverRatingTag[] {
  const allowed: readonly string[] = stars >= 4 ? POSITIVE_TAGS : NEGATIVE_TAGS;
  return [...new Set(tags)].filter((t): t is DriverRatingTag => allowed.includes(t));
}

/** The smoothed score dispatch ranks on. */
export function dispatchRating(sum: number, count: number): number {
  const score = (sum + PRIOR_RATING * PRIOR_WEIGHT) / (count + PRIOR_WEIGHT);
  return Math.round(score * 100) / 100;
}

/** The plain average a person reads, or 0 before the first rating. */
export function averageRating(sum: number, count: number): number {
  return count === 0 ? 0 : Math.round((sum / count) * 10) / 10;
}

export interface FeedbackItem {
  stars: number;
  tags: string[];
  comment: string;
}

/** What one rating adds to the chofer's record. */
export interface DriverRatingSummary {
  ratingSum: number;
  ratingCount: number;
  /** Dispatch score, see [dispatchRating]. */
  rating: number;
  /** Ratings per star, keyed '1'…'5'. */
  ratingStars: Record<string, number>;
  /** How often each tag was given. */
  ratingTags: Record<string, number>;
  /**
   * The latest [RECENT_FEEDBACK_LIMIT] reviews, newest first, with no service
   * or customer on them: what the chofer reads about themselves.
   */
  recentFeedback: FeedbackItem[];
}

/** Folds one rating into the chofer's summary. Pure: the caller writes it. */
export function applyRating(
  current: Partial<DriverRatingSummary>,
  rating: FeedbackItem,
): DriverRatingSummary {
  const ratingSum = (current.ratingSum ?? 0) + rating.stars;
  const ratingCount = (current.ratingCount ?? 0) + 1;

  const ratingStars = { ...(current.ratingStars ?? {}) };
  const key = `${rating.stars}`;
  ratingStars[key] = (ratingStars[key] ?? 0) + 1;

  const ratingTags = { ...(current.ratingTags ?? {}) };
  for (const tag of rating.tags) ratingTags[tag] = (ratingTags[tag] ?? 0) + 1;

  const recentFeedback = [
    { stars: rating.stars, tags: [...rating.tags], comment: rating.comment },
    ...(current.recentFeedback ?? []),
  ].slice(0, RECENT_FEEDBACK_LIMIT);

  return {
    ratingSum,
    ratingCount,
    rating: dispatchRating(ratingSum, ratingCount),
    ratingStars,
    ratingTags,
    recentFeedback,
  };
}

/** Whether a tow that finished at [finishedAt] can still be rated at [now]. */
export function withinRatingWindow(finishedAt: Date | undefined, now: Date): boolean {
  if (!finishedAt) return true;
  return now.getTime() - finishedAt.getTime() <= RATING_WINDOW_DAYS * 24 * 60 * 60 * 1000;
}
