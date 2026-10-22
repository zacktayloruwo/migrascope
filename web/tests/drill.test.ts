// Every drill-down the app offers must lead somewhere: a drilled view always
// shows at least one named category with a non-zero value (dead ends used to
// show a lone "NA" bar, or an empty chart of zeros).
// A blank bucket may still appear beside named ones where the source splits a
// category only partly - e.g. IMP "work purposes only" > Significant benefit,
// broken down only for a few small provinces - and the app labels that bucket
// "<parent> (no further breakdown)". Walks every (theme, geographic level,
// series, breakdown) in the exported data, every drill value offered at level
// 1, and every level-2 value under those.

import { describe, expect, test } from 'vitest'
import fs from 'node:fs'
import path from 'node:path'
import { decodeSeriesFacts } from '../src/query/columns'
import { drillableValues } from '../src/query/drill'
import { buildPlotData, type ViewParams } from '../src/query/plotData'

const DATA = path.resolve(import.meta.dirname, '..', 'public', 'data')
const manifest = JSON.parse(fs.readFileSync(path.join(DATA, 'manifest.json'), 'utf8')) as {
  series_facts: { theme: string; geo_level: string; path: string }[]
}
const summary = JSON.parse(fs.readFileSync(path.join(DATA, 'series_summary.json'), 'utf8')) as {
  theme: string; series: string; facet: string; geo_level: string; geo_depth: number
  has_breakdown_2: boolean; is_stock: boolean; min_year: number; max_year: number
}[]

describe('every offered drill-down shows named categories', () => {
  for (const part of manifest.series_facts) {
    const rows = summary.filter((r) => r.theme === part.theme && r.geo_level === part.geo_level &&
      r.facet !== 'Total' && r.has_breakdown_2)
    if (rows.length === 0) continue
    test(`${part.theme} / ${part.geo_level} (${rows.length} breakdowns)`, async () => {
      const buf = fs.readFileSync(path.join(DATA, part.path))
      const cols = await decodeSeriesFacts(buf.buffer.slice(buf.byteOffset, buf.byteOffset + buf.byteLength))
      let checked = 0
      for (const r of rows) {
        const base: ViewParams = {
          series: r.series, facet: r.facet, geoLevel: r.geo_level, geoDepth: r.geo_depth, granularity: 'Annual',
          years: [r.min_year, r.max_year], isStock: r.is_stock, topN: 15, displayAs: 'absolute',
          // A place is chosen whenever a breakdown is shown below National; the
          // drill rule is per category, so "every place" covers the same rows.
          geoUnitPrefix: [], drill1: null, drill2: null
        }
        for (const d1 of drillableValues(cols, r.series, r.facet)) {
          const level1 = buildPlotData(cols, { ...base, drill1: d1 })
          expect(level1.rows.some((x) => x.category !== null && x.value !== 0), `${r.series} > ${r.facet} > ${d1}`).toBe(true)
          checked++
          for (const d2 of drillableValues(cols, r.series, r.facet, d1)) {
            const level2 = buildPlotData(cols, { ...base, drill1: d1, drill2: d2 })
            expect(level2.rows.some((x) => x.category !== null && x.value !== 0), `${r.series} > ${r.facet} > ${d1} > ${d2}`).toBe(true)
            checked++
          }
        }
      }
      expect(checked).toBeGreaterThan(0)
    }, 60_000) // the largest partitions take several seconds on CI runners
  }
})
