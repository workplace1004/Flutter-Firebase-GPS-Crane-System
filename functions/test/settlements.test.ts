import { readFileSync } from 'node:fs';

import { describe, expect, it } from 'vitest';

import {
  type SettleableEntry,
  draftSettlement,
  payByFor,
} from '../src/lib/settlements.js';

/**
 * The weekly corte's arithmetic, on the office's own worked example:
 * Carlos, Grúa 07, the week of Monday 2 to Friday 6 September 2024.
 */

// Dominican time is UTC-4: 10:00 in Santo Domingo is 14:00Z.
const at = (iso: string) => new Date(`${iso}-04:00`);

let seq = 0;
const insurer = (grossPesos: number, netPesos: number, when: string): SettleableEntry => ({
  serviceId: `ins-${++seq}`,
  serviceCode: `GR-INS-${seq}`,
  method: 'insurer',
  grossCents: grossPesos * 100,
  commissionCents: (grossPesos - netPesos) * 100,
  netCents: netPesos * 100,
  completedAt: at(when),
});
const cash = (grossPesos: number, commissionPesos: number, when: string): SettleableEntry => ({
  serviceId: `cash-${++seq}`,
  serviceCode: `GR-CASH-${seq}`,
  method: 'cash',
  grossCents: grossPesos * 100,
  commissionCents: commissionPesos * 100,
  netCents: (grossPesos - commissionPesos) * 100,
  completedAt: at(when),
});

const FRIDAY_8AM = at('2024-09-06T08:00:00');

describe('Carlos’s corte', () => {
  const entries = [
    insurer(3_500, 2_450, '2024-09-02T09:15:00'),
    insurer(5_500, 3_850, '2024-09-03T14:00:00'),
    insurer(2_500, 1_750, '2024-09-04T11:30:00'),
    cash(4_000, 800, '2024-09-04T16:45:00'),
    cash(5_000, 1_000, '2024-09-05T10:20:00'),
  ];
  const draft = draftSettlement(entries, { cutoff: FRIDAY_8AM })!;

  it('section 1: Drakegruas owes RD$8,050 for three insurer jobs', () => {
    const lines = draft.lines.filter((l) => l.kind === 'insurer');
    expect(lines.map((l) => l.amountCents)).toEqual([245_000, 385_000, 175_000]);
    expect(lines.map((l) => l.grossCents)).toEqual([350_000, 550_000, 250_000]);
    expect(draft.insuranceOwedCents).toBe(805_000);
  });

  it('section 2: Carlos owes RD$1,800 for two cash jobs', () => {
    const lines = draft.lines.filter((l) => l.kind === 'cash');
    expect(lines.map((l) => l.amountCents)).toEqual([80_000, 100_000]);
    expect(draft.commissionOwedCents).toBe(180_000);
  });

  it('section 3: Drakegruas pays Carlos RD$6,250', () => {
    expect(draft.finalBalanceCents).toBe(625_000);
    expect(draft.direction).toBe('to_driver');
  });

  it('runs from the first job to the cutoff, in order', () => {
    expect(draft.periodStart).toEqual(at('2024-09-02T09:15:00'));
    expect(draft.periodEnd).toEqual(FRIDAY_8AM);
    const times = draft.lines.map((l) => l.completedAt.getTime());
    expect(times).toEqual([...times].sort((a, b) => a - b));
  });
});

describe('the other examples', () => {
  it('two insurer jobs worth RD$5,000 less one cash commission of RD$800: +RD$4,200', () => {
    const draft = draftSettlement(
      [
        insurer(3_500, 2_450, '2024-09-02T09:00:00'),
        insurer(3_643, 2_550, '2024-09-03T09:00:00'),
        cash(4_000, 800, '2024-09-04T09:00:00'),
      ],
      { cutoff: FRIDAY_8AM },
    )!;
    expect(draft.insuranceOwedCents).toBe(500_000);
    expect(draft.finalBalanceCents).toBe(420_000);
    expect(draft.direction).toBe('to_driver');
  });

  it('a week of cash only: the chofer pays Drakegruas', () => {
    const draft = draftSettlement(
      [cash(4_000, 800, '2024-09-02T09:00:00'), cash(5_000, 1_000, '2024-09-03T09:00:00')],
      { cutoff: FRIDAY_8AM },
    )!;
    expect(draft.insuranceOwedCents).toBe(0);
    expect(draft.finalBalanceCents).toBe(-180_000);
    expect(draft.direction).toBe('to_company');
  });

  it('a week that nets to zero moves no money', () => {
    const draft = draftSettlement(
      [insurer(1_143, 800, '2024-09-02T09:00:00'), cash(4_000, 800, '2024-09-03T09:00:00')],
      { cutoff: FRIDAY_8AM },
    )!;
    expect(draft.finalBalanceCents).toBe(0);
    expect(draft.direction).toBe('none');
  });
});

describe('what a corte takes', () => {
  it('nothing, when there is nothing', () => {
    expect(draftSettlement([], { cutoff: FRIDAY_8AM })).toBeNull();
  });

  it('leaves a job finished after the cutoff for next week', () => {
    const draft = draftSettlement(
      [
        insurer(2_500, 1_750, '2024-09-05T09:00:00'),
        insurer(3_500, 2_450, '2024-09-06T08:00:01'),
      ],
      { cutoff: FRIDAY_8AM },
    )!;
    expect(draft.lines).toHaveLength(1);
    expect(draft.insuranceOwedCents).toBe(175_000);
  });

  it('takes a job finished exactly at the cutoff', () => {
    const draft = draftSettlement([insurer(2_500, 1_750, '2024-09-06T08:00:00')], {
      cutoff: FRIDAY_8AM,
    });
    expect(draft?.lines).toHaveLength(1);
  });

  it('leaves out jobs from before weekly cortes began', () => {
    const draft = draftSettlement(
      [
        cash(4_000, 800, '2024-08-20T09:00:00'),
        cash(5_000, 1_000, '2024-09-03T09:00:00'),
      ],
      { cutoff: FRIDAY_8AM, startAt: at('2024-09-02T00:00:00') },
    )!;
    expect(draft.commissionOwedCents).toBe(100_000);
    expect(draft.lines).toHaveLength(1);
  });

  it('ignores an entry with no completion time', () => {
    const entry = { ...insurer(2_500, 1_750, '2024-09-02T09:00:00'), completedAt: null };
    expect(draftSettlement([entry], { cutoff: FRIDAY_8AM })).toBeNull();
  });

  it('does not charge commission twice on cash already handed in at the office', () => {
    const counted = { ...cash(4_000, 800, '2024-09-02T09:00:00'), countedInCashCorte: true };
    const draft = draftSettlement(
      [counted, cash(5_000, 1_000, '2024-09-03T09:00:00')],
      { cutoff: FRIDAY_8AM },
    )!;
    expect(draft.commissionOwedCents).toBe(100_000);
    expect(draft.retired).toEqual([{ serviceId: counted.serviceId, reason: 'cash_corte' }]);
    expect(draft.lines.some((l) => l.serviceId === counted.serviceId)).toBe(false);
  });

  it('retires cash already handed in even when there is nothing else', () => {
    const counted = { ...cash(4_000, 800, '2024-09-02T09:00:00'), countedInCashCorte: true };
    const draft = draftSettlement([counted], { cutoff: FRIDAY_8AM })!;
    expect(draft.lines).toEqual([]);
    expect(draft.finalBalanceCents).toBe(0);
    expect(draft.retired).toHaveLength(1);
  });

  it('leaves card jobs for a person to look at, rather than paying them', () => {
    const card = { ...insurer(2_500, 2_000, '2024-09-02T09:00:00'), method: 'card' };
    const draft = draftSettlement(
      [card, cash(4_000, 800, '2024-09-03T09:00:00')],
      { cutoff: FRIDAY_8AM },
    )!;
    expect(draft.ignored).toEqual([{ serviceId: card.serviceId, reason: 'unsupported_method' }]);
    expect(draft.finalBalanceCents).toBe(-80_000);
    expect(draftSettlement([card], { cutoff: FRIDAY_8AM })).toBeNull();
  });
});

describe('payByFor', () => {
  const fivePm = (day: string) => at(`${day}T17:00:00`);

  it('is 5 p.m. the same Friday when the corte is made that morning', () => {
    expect(payByFor(FRIDAY_8AM)).toEqual(fivePm('2024-09-06'));
    expect(payByFor(at('2024-09-06T00:30:00'))).toEqual(fivePm('2024-09-06'));
  });

  it('is next Friday when made after 5 p.m. on a Friday', () => {
    expect(payByFor(at('2024-09-06T17:00:00'))).toEqual(fivePm('2024-09-13'));
    expect(payByFor(at('2024-09-06T22:00:00'))).toEqual(fivePm('2024-09-13'));
  });

  it('is the coming Friday on any other day', () => {
    expect(payByFor(at('2024-09-02T10:00:00'))).toEqual(fivePm('2024-09-06'));
    expect(payByFor(at('2024-09-07T09:00:00'))).toEqual(fivePm('2024-09-13'));
    expect(payByFor(at('2024-09-08T23:59:00'))).toEqual(fivePm('2024-09-13'));
  });

  it('counts the day in Dominican time, not UTC', () => {
    // Thursday 21:30 in Santo Domingo is already Friday in UTC.
    expect(payByFor(at('2024-09-05T21:30:00'))).toEqual(fivePm('2024-09-06'));
    // Friday 20:30 in Santo Domingo is already Saturday in UTC.
    expect(payByFor(at('2024-09-06T20:30:00'))).toEqual(fivePm('2024-09-13'));
  });
});

describe('the shared examples', () => {
  interface Case {
    name: string;
    cutoff: string;
    startAt?: string;
    entries: Array<Omit<SettleableEntry, 'completedAt' | 'serviceCode'> & { completedAt: string | null }>;
    expected: null | {
      insuranceOwedCents: number;
      commissionOwedCents: number;
      finalBalanceCents: number;
      direction: string;
      lineIds: string[];
      lineAmounts: number[];
      periodStart: string;
      retired: string[];
      ignored: string[];
    };
  }
  const fixture = JSON.parse(
    readFileSync(
      new URL('../../packages/grua_core/test/fixtures/settlement_cases.json', import.meta.url),
      'utf8',
    ),
  ) as { cases: Case[]; payBy: Array<{ from: string; payBy: string }> };

  for (const c of fixture.cases) {
    it(c.name, () => {
      const draft = draftSettlement(
        c.entries.map((e) => ({
          ...e,
          serviceCode: '',
          completedAt: e.completedAt ? new Date(e.completedAt) : null,
        })),
        { cutoff: new Date(c.cutoff), startAt: c.startAt ? new Date(c.startAt) : null },
      );
      if (c.expected === null) {
        expect(draft).toBeNull();
        return;
      }
      expect(draft).not.toBeNull();
      expect(draft!.insuranceOwedCents).toBe(c.expected.insuranceOwedCents);
      expect(draft!.commissionOwedCents).toBe(c.expected.commissionOwedCents);
      expect(draft!.finalBalanceCents).toBe(c.expected.finalBalanceCents);
      expect(draft!.direction).toBe(c.expected.direction);
      expect(draft!.lines.map((l) => l.serviceId)).toEqual(c.expected.lineIds);
      expect(draft!.lines.map((l) => l.amountCents)).toEqual(c.expected.lineAmounts);
      expect(draft!.periodStart).toEqual(new Date(c.expected.periodStart));
      expect(draft!.retired.map((r) => r.serviceId)).toEqual(c.expected.retired);
      expect(draft!.ignored.map((r) => r.serviceId)).toEqual(c.expected.ignored);
    });
  }

  for (const c of fixture.payBy) {
    it(`pays a corte made ${c.from} by ${c.payBy}`, () => {
      expect(payByFor(new Date(c.from))).toEqual(new Date(c.payBy));
    });
  }
});
