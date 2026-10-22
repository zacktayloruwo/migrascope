// Which categories are worth drilling into. IRCC's hierarchies are ragged:
// "Economic" splits into programs, but "Sponsored Family" has no finer level
// in most tables, so drilling into it just returned one unlabelled bar ("NA").
// Every category in the data is either fully split or not split at all, so a
// category is offered as a drill target only if it has at least one child -
// and one that is non-zero somewhere: some splits exist only as zero rows
// (e.g. TR to PR "Prior IMP, work purposes only" > Resettled Refugee, whose
// two refugee types are 0 in every year and place), and drilling into those
// showed an empty chart.
// UI-only: listBreakdownValues() stays as the R app's parity reference.

import type { SeriesFactsColumns } from './columns'
import { listBreakdownValues } from './plotData'

/**
 * Drill-down choices that actually split further: breakdown_1 values with a
 * breakdown_2 below them, or (given `drill1`) breakdown_2 values under it with
 * a breakdown_3 below them. A child counts only if its value is non-zero.
 */
export function drillableValues(cols: SeriesFactsColumns, series: string, facet: string,
                                drill1: string | null = null): string[] {
  const parent = drill1 == null ? cols.breakdown_1 : cols.breakdown_2
  const child = drill1 == null ? cols.breakdown_2 : cols.breakdown_3
  const splits = new Set<string>()
  for (let i = 0; i < cols.length; i++) {
    if (cols.series[i] !== series || cols.facet[i] !== facet) continue
    if (drill1 != null && cols.breakdown_1[i] !== drill1) continue
    const p = parent[i]
    const v = cols.value[i]
    if (p != null && child[i] != null && v != null && v !== 0) splits.add(p)
  }
  return listBreakdownValues(cols, series, facet, drill1).filter((v) => splits.has(v))
}
