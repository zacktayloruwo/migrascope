// Which plotted periods are incomplete - e.g. 2026 when the data runs only
// to July. The chart marks these columns with an asterisk and the Note names the months
// they cover. Uses the same row selection as the chart (fetchSeriesRows), so
// the two can't disagree. Not part of the R app; no parity tests involved.

import type { SeriesFactsColumns } from './columns'
import { fetchSeriesRows, type ViewParams } from './plotData'

export interface PartialPeriod {
  /** The period's label as plotted ("2026", "2026 Q3"). */
  period: string
  year: number
  /** First and last month with data, or null when the period has only an annual figure. */
  months: [number, number] | null
}

/**
 * @param dataThrough the latest month in the data overall ("2026-07"). A year
 *   with no monthly rows is treated as partial only when it is that year
 *   still in progress - e.g. IRB's annual refugee table, republished
 *   quarterly with a year-to-date current year.
 */
export function partialPeriods(cols: SeriesFactsColumns, p: ViewParams, dataThrough: string): PartialPeriod[] {
  if (p.granularity === 'Monthly') return []
  const [throughYear, throughMonth] = dataThrough.split('-').map(Number)

  // months seen per year (and per quarter), across every row the chart uses
  const byYear = new Map<number, Set<number>>()
  const byQuarter = new Map<string, Set<number>>()
  const years = new Set<number>()
  for (const r of fetchSeriesRows(cols, p)) {
    years.add(r.year)
    if (r.month == null) continue
    if (!byYear.has(r.year)) byYear.set(r.year, new Set())
    byYear.get(r.year)!.add(r.month)
    if (r.quarter != null) {
      const k = `${r.year} Q${r.quarter}`
      if (!byQuarter.has(k)) byQuarter.set(k, new Set())
      byQuarter.get(k)!.add(r.month)
    }
  }
  const span = (months: Set<number>): [number, number] => [Math.min(...months), Math.max(...months)]
  const out: PartialPeriod[] = []

  if (p.granularity === 'Annual') {
    for (const year of [...years].sort((a, b) => a - b)) {
      const months = byYear.get(year)
      if (months) {
        if (months.size < 12) out.push({ period: String(year), year, months: span(months) })
      } else if (year === throughYear && throughMonth < 12) {
        out.push({ period: String(year), year, months: null })
      }
    }
  } else {
    for (const [period, months] of [...byQuarter.entries()].sort()) {
      if (months.size < 3) out.push({ period, year: Number(period.slice(0, 4)), months: span(months) })
    }
  }
  return out
}
