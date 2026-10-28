// Level series (a score, not a count - the Express Entry CRS cutoff) and
// event series (Express Entry draws). Neither exists in the R app, so the
// golden parity tests don't cover them; these do, on small hand-made data.

import { describe, expect, test } from 'vitest'
import type { SeriesFactsColumns } from '../src/query/columns'
import { partialPeriods } from '../src/query/partial'
import { buildPlotData, isScoreRangeView, orderScoreRanges, type ViewParams } from '../src/query/plotData'

/** Columns from [category, year, month, value] rows of one National series. */
function columns(rows: [string, number, number, number][], series = 'S', facet = 'Round Type'): SeriesFactsColumns {
  const n = rows.length
  const nulls = () => new Array<null>(n).fill(null)
  return {
    length: n,
    series: new Array(n).fill(series),
    facet: new Array(n).fill(facet),
    breakdown_1: rows.map((r) => r[0]),
    breakdown_2: nulls(), breakdown_3: nulls(), geo_1: nulls(), geo_2: nulls(), geo_3: nulls(),
    period_year: rows.map((r) => r[1]),
    period_quarter: rows.map((r) => Math.ceil(r[2] / 3)),
    period_month: rows.map((r) => r[2]),
    value: rows.map((r) => r[3]),
    source_table_id: new Array(n).fill('express_entry/ee000123__rounds')
  }
}

const params = (over: Partial<ViewParams>): ViewParams => ({
  series: 'S', facet: 'Round Type', geoLevel: 'National', geoDepth: 0, granularity: 'Annual',
  years: [2015, 2026], isStock: false, topN: 2, displayAs: 'absolute', geoUnitPrefix: [],
  drill1: null, drill2: null, ...over
})

const value = (d: ReturnType<typeof buildPlotData>, category: string, period: string) =>
  d.rows.find((r) => r.category === category && r.period === period)?.value

describe('level series', () => {
  const cols = columns([
    ['A', 2024, 1, 520], ['A', 2024, 2, 480], ['A', 2024, 5, 500],
    ['B', 2024, 2, 700], ['C', 2024, 3, 400], ['D', 2024, 4, 450]
  ])

  test('periods take the lowest value, not the sum', () => {
    const annual = buildPlotData(cols, params({ level: true }))
    expect(value(annual, 'A', '2024')).toBe(480)
    const quarterly = buildPlotData(cols, params({ level: true, granularity: 'Quarterly' }))
    expect(value(quarterly, 'A', '2024 Q1')).toBe(480)
    expect(value(quarterly, 'A', '2024 Q2')).toBe(500)
  })

  test('no "Other", Suppressed Residual or percentage', () => {
    const d = buildPlotData(cols, params({ level: true, topN: 2, displayAs: 'percent' }))
    expect(d.categoryOrder.sort()).toEqual(['A', 'B', 'C', 'D'])
    expect(value(d, 'B', '2024')).toBe(700)
  })

  test('a count series still sums', () => {
    expect(value(buildPlotData(cols, params({ topN: 10 })), 'A', '2024')).toBe(1500)
  })
})

describe('event series: only the latest period can be partial', () => {
  // draws in some months only, ending in October 2026
  const cols = columns([['A', 2025, 1, 10], ['A', 2025, 6, 10], ['A', 2025, 11, 10],
                        ['A', 2026, 2, 10], ['A', 2026, 10, 10]])

  test('annual: 2025 (no December draw) is complete, 2026 is partial', () => {
    const p = partialPeriods(cols, params({ events: true }), '2026-07')
    expect(p).toEqual([{ period: '2026', year: 2026, months: [1, 10] }])
  })

  test('quarterly: only the quarter in progress', () => {
    const p = partialPeriods(cols, params({ events: true, granularity: 'Quarterly' }), '2026-07')
    expect(p.map((x) => x.period)).toEqual(['2026 Q4'])
  })

  test('without the flag, gaps between draws would mark years partial', () => {
    expect(partialPeriods(cols, params({}), '2026-07').map((x) => x.period)).toEqual(['2025', '2026'])
  })
})

describe('CRS score ranges stack lowest at the bottom', () => {
  const data = (categoryOrder: string[]) => ({ categoryOrder, periodOrder: [], rows: [] })

  test('pool ranges: highest first in categoryOrder (top of the stack)', () => {
    const d = data(['451-500', '401-450', '351-400', '501-600', '0-300', '601-1200', '301-350'])
    expect(isScoreRangeView(d)).toBe(true)
    expect(orderScoreRanges(d).categoryOrder).toEqual(['601-1200', '501-600', '451-500', '401-450', '351-400', '301-350', '0-300'])
  })

  test('"Score 251 - 300" labels, with "Other" and the residual kept after them', () => {
    const d = data(['Score 451 - 500', 'Score 1001 - 1100', 'Score 251 - 300', 'Other', 'Suppressed Residual'])
    expect(isScoreRangeView(d)).toBe(true)
    expect(orderScoreRanges(d).categoryOrder).toEqual(['Score 1001 - 1100', 'Score 451 - 500', 'Score 251 - 300', 'Other', 'Suppressed Residual'])
  })

  test('other views are left alone', () => {
    expect(isScoreRangeView(data(['15 to 29 years old', '0 to 14 years old']))).toBe(false)
    expect(isScoreRangeView(data(['Canadian Experience Class', '451-500']))).toBe(false)
  })
})
