// Level series (a score, not a count - the Express Entry CRS cutoff) and
// draw series (Express Entry rounds, one period per draw). Neither exists in the R app, so the
// golden parity tests don't cover them; these do, on small hand-made data.

import { describe, expect, test } from 'vitest'
import type { SeriesFactsColumns } from '../src/query/columns'
import { partialPeriods } from '../src/query/partial'
import { buildDrawPlotData, buildPlotData, isScoreRangeView, orderScoreRanges, type DrawData, type ViewParams } from '../src/query/plotData'

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

describe('draw series: one period per draw', () => {
  // three draws: two on one day (as with 91a/91b in 2018), one in 2024
  const d: DrawData = {
    theme: 'express_entry',
    draws: { draw: ['91a', '91b', '300'], date: ['2018-05-30', '2018-05-30', '2024-07-02'],
             round: ['Federal Skilled Trades', 'Provincial Nominee Program', 'Canadian Experience Class'],
             round_fr: [null, null, null], pool_as_on: [null, null, '2024-06-30'] },
    facts: {
      series: ['Inv', 'Inv', 'Inv', 'Cut', 'Cut', 'Cut'],
      facet: ['Round Type', 'Round Type', 'Round Type', 'Round Type', 'Round Type', 'Round Type'],
      breakdown_1: ['Program-specific', 'Program-specific', 'Program-specific', 'Program-specific', 'Program-specific', 'Program-specific'],
      breakdown_2: ['FST', 'PNP', 'CEC', 'FST', 'PNP', 'CEC'],
      draw_index: [0, 1, 2, 0, 1, 2],
      value: [500, 200, 3000, 288, 902, 515]
    }
  }

  test('each draw is its own period, in date order, labelled by date and number', () => {
    const out = buildDrawPlotData(d, params({ series: 'Inv', granularity: 'Draw', drill1: 'Program-specific', topN: 10 }))
    expect(out.periodOrder).toEqual(['2018-05-30 #91a', '2018-05-30 #91b', '2024-07-02 #300'])
    expect(value(out, 'PNP', '2018-05-30 #91b')).toBe(200)
    // only the pool series names the pool count's date
    expect(out.draws!['2024-07-02 #300'].pool_as_on).toBeNull()
    const pool = { ...d, facts: { ...d.facts, series: d.facts.series.map(() => 'Candidates in the pool') } }
    expect(buildDrawPlotData(pool, params({ series: 'Candidates in the pool', granularity: 'Draw', drill1: 'Program-specific', topN: 10 }))
      .draws!['2024-07-02 #300'].pool_as_on).toBe('2024-06-30')
  })

  test('not summed into months or years', () => {
    const out = buildDrawPlotData(d, params({ series: 'Inv', granularity: 'Draw', topN: 10 }))
    expect(value(out, 'Program-specific', '2018-05-30 #91a')).toBe(500)
    expect(value(out, 'Program-specific', '2018-05-30 #91b')).toBe(200)
  })

  test('the year range filters draws; a level keeps each draw\'s own score', () => {
    const out = buildDrawPlotData(d, params({ series: 'Cut', granularity: 'Draw', level: true, drill1: 'Program-specific', years: [2024, 2026] }))
    expect(out.periodOrder).toEqual(['2024-07-02 #300'])
    expect(value(out, 'CEC', '2024-07-02 #300')).toBe(515)
  })

  test('no partial periods for draws', () => {
    expect(partialPeriods(columns([['A', 2026, 10, 1]]), params({ granularity: 'Draw' }), '2026-07')).toEqual([])
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
