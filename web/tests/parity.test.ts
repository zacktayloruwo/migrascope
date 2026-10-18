// Parity between the TypeScript query layer (src/query/) and the Shiny app's
// R implementation. Golden files come from data-raw/11_export_golden.R; the
// Parquet partitions come from data-raw/10_export_web.R. Both must be
// regenerated together after a data refresh.

import { describe, expect, test } from 'vitest'
import fs from 'node:fs'
import path from 'node:path'
import { decodeSeriesFacts, type SeriesFactsColumns } from '../src/query/columns'
import { buildPlotData, listBreakdownValues, type Granularity, type PlotData } from '../src/query/plotData'

const ROOT = path.resolve(import.meta.dirname, '..')
const DATA = path.join(ROOT, 'public', 'data')
const GOLDEN = path.join(ROOT, 'tests', 'golden')

interface GoldenCase {
  theme: string
  series: string
  facet: string
  geo_level: string
  geo_depth: number
  granularity: Granularity
  years: [number, number]
  is_stock: boolean
  top_n: number
  display_as: 'absolute' | 'percent'
  geo_unit_prefix: string[]
  drill_1: string | null
  drill_2: string | null
  expected: {
    category_order: string[]
    period_order: string[]
    rows: { category: string | null; period: string; value: number }[]
  }
}

interface BreakdownCase {
  theme: string
  series: string
  facet: string
  geo_level: string
  drill_1: string | null
  expected: string[]
}

const manifest = JSON.parse(fs.readFileSync(path.join(DATA, 'manifest.json'), 'utf8')) as {
  series_facts: { theme: string; geo_level: string; path: string }[]
}
const partitions = new Map<string, Promise<SeriesFactsColumns>>()
function partition(theme: string, geoLevel: string): Promise<SeriesFactsColumns> {
  const key = `${theme}/${geoLevel}`
  if (!partitions.has(key)) {
    const entry = manifest.series_facts.find((f) => f.theme === theme && f.geo_level === geoLevel)
    if (!entry) throw new Error(`no partition for ${key}`)
    const buf = fs.readFileSync(path.join(DATA, entry.path))
    partitions.set(key, decodeSeriesFacts(buf.buffer.slice(buf.byteOffset, buf.byteOffset + buf.byteLength)))
  }
  return partitions.get(key)!
}

function describeCase(c: GoldenCase): string {
  const parts = [c.series, c.facet, c.geo_level, c.granularity, `${c.years[0]}-${c.years[1]}`]
  if (c.geo_unit_prefix.length) parts.push(`@${c.geo_unit_prefix.join('/')}`)
  if (c.drill_1) parts.push(`>${c.drill_1}`)
  if (c.drill_2) parts.push(`>${c.drill_2}`)
  if (c.display_as === 'percent') parts.push('%')
  if (c.top_n !== 10) parts.push(`top${c.top_n}`)
  return parts.join(' | ')
}

/** Rows keyed by (category, period), summed in case of duplicates. */
function keyed(rows: { category: string | null; period: string; value: number }[]): Map<string, number> {
  const m = new Map<string, number>()
  for (const r of rows) {
    const k = `${r.category ?? '∅'}␟${r.period}`
    m.set(k, (m.get(k) ?? 0) + r.value)
  }
  return m
}

function assertMatches(actual: PlotData, expected: GoldenCase['expected']) {
  expect(actual.categoryOrder).toEqual(expected.category_order)
  expect(actual.periodOrder).toEqual(expected.period_order)
  const a = keyed(actual.rows)
  const e = keyed(expected.rows)
  expect([...a.keys()].sort()).toEqual([...e.keys()].sort())
  for (const [k, ev] of e) {
    const av = a.get(k)!
    if (Math.abs(av - ev) > 1e-9 * Math.max(1, Math.abs(ev))) {
      throw new Error(`value mismatch at ${k}: got ${av}, expected ${ev}`)
    }
  }
}

const goldenFiles = fs.readdirSync(GOLDEN).filter((f) => f.endsWith('.json') && f !== 'breakdown_values.json')

for (const file of goldenFiles) {
  const cases = JSON.parse(fs.readFileSync(path.join(GOLDEN, file), 'utf8')) as GoldenCase[]
  describe(`plot data: ${file.replace('.json', '')}`, () => {
    test.each(cases.map((c) => [describeCase(c), c] as const))('%s', async (_name, c) => {
      const cols = await partition(c.theme, c.geo_level)
      const actual = buildPlotData(cols, {
        series: c.series, facet: c.facet, geoLevel: c.geo_level, geoDepth: c.geo_depth,
        granularity: c.granularity, years: c.years, isStock: c.is_stock, topN: c.top_n,
        displayAs: c.display_as, geoUnitPrefix: c.geo_unit_prefix, drill1: c.drill_1, drill2: c.drill_2
      })
      assertMatches(actual, c.expected)
    })
  })
}

// The pre-aggregated first chart per theme (views/<theme>.default.json) is
// shown before any Parquet loads, so it must equal what the live query layer
// computes for the same inputs.
describe('pre-aggregated default views', () => {
  const files = fs.readdirSync(path.join(DATA, 'views')).filter((f) => f.endsWith('.default.json'))
  test.each(files)('%s', async (file) => {
    const v = JSON.parse(fs.readFileSync(path.join(DATA, 'views', file), 'utf8'))
    const cols = await partition(v.theme, v.geo_level)
    const actual = buildPlotData(cols, {
      series: v.series, facet: v.facet, geoLevel: v.geo_level, geoDepth: v.geo_depth,
      granularity: v.granularity, years: v.years, isStock: v.is_stock, topN: v.top_n,
      displayAs: v.display_as, geoUnitPrefix: [], drill1: null, drill2: null
    })
    assertMatches(actual, { category_order: v.category_order, period_order: v.period_order, rows: v.rows })
  })
})

describe('drill-down choices', () => {
  const cases = JSON.parse(fs.readFileSync(path.join(GOLDEN, 'breakdown_values.json'), 'utf8')) as BreakdownCase[]
  test.each(cases.map((c) => [`${c.theme} | ${c.series} | ${c.facet} | ${c.geo_level}${c.drill_1 ? ` > ${c.drill_1}` : ''}`, c] as const))(
    '%s', async (_name, c) => {
      const cols = await partition(c.theme, c.geo_level)
      expect(listBreakdownValues(cols, c.series, c.facet, c.drill_1)).toEqual(c.expected)
    })
})
