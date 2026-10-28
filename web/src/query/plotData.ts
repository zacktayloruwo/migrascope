// TypeScript port of the Shiny app's plot-data pipeline (app/R/app_utils.R):
// fetch_series_rows() -> aggregate_series() -> collapse_to_top_n() + the
// Suppressed Residual -> order_categories() -> to_percent_of_total(), i.e.
// build_series_plot_data(). Behaviour, including the awkward edges (missing
// categories, stock series, years with no quarterly breakdown), is pinned to
// the R original by tests/parity.test.ts - change both together.
//
// Ordering note: dplyr's group_by()/arrange() sort strings in the C locale
// (plain code-unit order), while base R's sort() uses ICU collation; the two
// helpers below reproduce each where R uses it.

import type { SeriesFactsColumns } from './columns'
import { GEO_UNIT_SEP, NA_LABEL, ORDINAL_COHORT_REGEX, OTHER, PROVINCE_ABBR, PROVINCE_ORDER_WEST_TO_EAST,
         SUPPRESSED_RESIDUAL } from './constants'

export type Granularity = 'Annual' | 'Quarterly' | 'Monthly'

export interface ViewParams {
  series: string
  facet: string
  geoLevel: string
  /** How many geo_N columns are meaningful at this level (series_summary.geo_depth). */
  geoDepth: number
  granularity: Granularity
  years: [number, number]
  isStock: boolean
  topN: number
  displayAs: 'absolute' | 'percent'
  /** Exact geo_1..geo_k values of one chosen place; empty = every place / national. */
  geoUnitPrefix: string[]
  drill1: string | null
  drill2: string | null
  /**
   * A score rather than a count (series_summary.measure = "level", e.g. the
   * Express Entry CRS cutoff): periods take the lowest value, and there's no
   * Suppressed Residual, "Other" or percentage. Not in the R app.
   */
  level?: boolean
  /**
   * Irregular events (Express Entry draws, series_summary.events): a month
   * without one isn't missing data, so only the latest period can be partial.
   */
  events?: boolean
}

export interface PlotRow {
  /** null where the source category is missing (R's NA) - such rows are drawn but not in the legend. */
  category: string | null
  period: string
  periodSort: number
  value: number
}

export interface PlotData {
  categoryOrder: string[]
  periodOrder: string[]
  rows: PlotRow[]
}

interface RawRow {
  entity: string
  category: string | null
  year: number
  quarter: number | null
  month: number | null
  value: number | null
}

interface AggRow {
  category: string | null
  period: string
  periodSort: number
  value: number
}

// ---- ordering helpers --------------------------------------------------------

/** dplyr group_by()/arrange() order: C locale, missing values last. */
function compareC(a: string | null, b: string | null): number {
  if (a === b) return 0
  if (a === null) return 1
  if (b === null) return -1
  return a < b ? -1 : 1
}

/** Base R sort() order (ICU collation in the en_CA locale the pipeline runs in). */
const icu = new Intl.Collator('en-CA')

/** sum(x, na.rm = TRUE) */
function addNa(acc: number, x: number | null): number {
  return x == null || Number.isNaN(x) ? acc : acc + x
}

/** min(x, na.rm = TRUE), starting from Infinity (a group with no values stays Infinity). */
function minNa(acc: number, x: number | null): number {
  return x == null || Number.isNaN(x) ? acc : Math.min(acc, x)
}

/**
 * Group rows by a key, preserving each group's first-seen order, then sum -
 * or, with `lowest`, take the smallest value (level series).
 * Callers sort the result where R's output order matters.
 */
function groupSum<T>(rows: T[], key: (r: T) => string, init: (r: T) => AggRow, value: (r: T) => number | null,
                     lowest = false) {
  const groups = new Map<string, AggRow>()
  for (const r of rows) {
    const k = key(r)
    let g = groups.get(k)
    if (!g) { g = { ...init(r), value: lowest ? Infinity : 0 }; groups.set(k, g) }
    g.value = lowest ? minNa(g.value, value(r)) : addNa(g.value, value(r))
  }
  const out = [...groups.values()]
  return lowest ? out.filter((g) => Number.isFinite(g.value)) : out
}

/** Per-category totals in dplyr's order: group keys C-sorted, then a stable desc(total). */
function categoryTotalsDesc(rows: AggRow[]): { category: string | null; total: number }[] {
  const totals = new Map<string | null, number>()
  for (const r of rows) totals.set(r.category, addNa(totals.get(r.category) ?? 0, r.value))
  return [...totals.entries()]
    .map(([category, total]) => ({ category, total }))
    .sort((a, b) => compareC(a.category, b.category))
    .sort((a, b) => b.total - a.total) // Array.prototype.sort is stable
}

// ---- fetch_series_rows() --------------------------------------------------------

/**
 * Rows of one (series, facet, geo level) view, filtered to the year range,
 * an optional place, and optional drill values - with `category` set to
 * whichever column is the display axis. `facetOverride` fetches the facet
 * "Total" rows for the published total (no drills, same place).
 */
export function fetchSeriesRows(cols: SeriesFactsColumns, p: ViewParams, facetOverride?: string): RawRow[] {
  const facet = facetOverride ?? p.facet
  const drill1 = facetOverride ? null : p.drill1
  const drill2 = facetOverride ? null : p.drill2
  const geoCols = [cols.geo_1, cols.geo_2, cols.geo_3]
  const prefix = p.geoUnitPrefix

  let categoryOf: (i: number) => string | null
  if (facet === 'Total') {
    if (p.geoLevel === 'National' || prefix.length >= p.geoDepth) {
      categoryOf = () => 'Total'
    } else {
      const placeCol = geoCols[p.geoDepth - 1]
      categoryOf = p.geoDepth > 1
        ? (i) => {
            const abbr = cols.geo_1[i] == null ? undefined : PROVINCE_ABBR[cols.geo_1[i] as string]
            const place = placeCol[i]
            // R: ifelse(!is.na(abbr), paste0(place, ", ", abbr), place) - paste0 renders NA as "NA"
            return abbr !== undefined ? `${place ?? 'NA'}, ${abbr}` : place
          }
        : (i) => placeCol[i]
    }
  } else if (drill2 != null) {
    categoryOf = (i) => cols.breakdown_3[i]
  } else if (drill1 != null) {
    categoryOf = (i) => cols.breakdown_2[i]
  } else {
    categoryOf = (i) => cols.breakdown_1[i]
  }

  const out: RawRow[] = []
  const [y0, y1] = p.years
  for (let i = 0; i < cols.length; i++) {
    if (cols.series[i] !== p.series || cols.facet[i] !== facet) continue
    const year = cols.period_year[i]
    if (year == null || year < y0 || year > y1) continue
    let ok = true
    for (let g = 0; g < prefix.length; g++) {
      if (geoCols[g][i] !== prefix[g]) { ok = false; break }
    }
    if (!ok) continue
    if (drill1 != null && cols.breakdown_1[i] !== drill1) continue
    if (drill2 != null && cols.breakdown_2[i] !== drill2) continue
    // R: drilled in, a row with nothing at the next level isn't part of that breakdown
    if (drill1 != null && categoryOf(i) == null) continue
    out.push({
      entity: [cols.geo_1[i], cols.geo_2[i], cols.geo_3[i], cols.breakdown_1[i], cols.breakdown_2[i],
               cols.breakdown_3[i]].map((x) => x ?? '').join(GEO_UNIT_SEP),
      category: categoryOf(i),
      year,
      quarter: cols.period_quarter[i],
      month: cols.period_month[i],
      value: cols.value[i]
    })
  }
  return out
}

// ---- aggregate_series() ---------------------------------------------------------

/**
 * Stock series (point-in-time snapshots) aren't additive across months: for
 * each leaf entity keep its latest month in the target period, then sum. R:
 * slice_max(period_month, n = 1, with_ties = FALSE) - missing months rank last.
 */
function latestPerEntity(rows: RawRow[], periodKey: (r: RawRow) => string): RawRow[] {
  const best = new Map<string, RawRow>()
  for (const r of rows) {
    const k = `${r.entity}\u0000${r.category}\u0000${periodKey(r)}`
    const cur = best.get(k)
    if (!cur) { best.set(k, r); continue }
    if (r.month != null && (cur.month == null || r.month > cur.month)) best.set(k, r)
  }
  return [...best.values()]
}

export function aggregateSeries(raw: RawRow[], granularity: Granularity, isStock: boolean, level = false): AggRow[] {
  if (raw.length === 0) return []
  const catKey = (r: RawRow) => (r.category === null ? '\u0000NA' : r.category)
  const year = (r: RawRow) => String(r.year)

  if (granularity === 'Monthly') {
    return groupSum(raw, (r) => `${catKey(r)}\u0001${r.year}\u0001${r.month}`, (r) => ({
      category: r.category,
      period: r.month == null ? year(r) : `${r.year}-${String(r.month).padStart(2, '0')}`,
      periodSort: r.year * 100 + (r.month ?? 0),
      value: 0
    }), (r) => r.value, level)
  }

  if (granularity === 'Quarterly' && raw.some((r) => r.quarter != null)) {
    const rows = isStock ? latestPerEntity(raw, (r) => `${r.year}|${r.quarter}`) : raw
    return groupSum(rows, (r) => `${catKey(r)}\u0001${r.year}\u0001${r.quarter}`, (r) => ({
      category: r.category,
      period: r.quarter == null ? year(r) : `${r.year} Q${r.quarter}`,
      periodSort: r.year * 10 + (r.quarter ?? 0),
      value: 0
    }), (r) => r.value, level)
  }

  // Annual - also the fallback for Quarterly when no row has a quarter.
  const rows = isStock ? latestPerEntity(raw, (r) => `${r.year}`) : raw
  return groupSum(rows, (r) => `${catKey(r)}\u0001${r.year}`, (r) => ({
    category: r.category, period: year(r), periodSort: r.year, value: 0
  }), (r) => r.value, level)
}

// ---- collapse_to_top_n() --------------------------------------------------------

export function collapseToTopN(d: AggRow[], topN: number): AggRow[] {
  if (d.length === 0) return d
  const totals = categoryTotalsDesc(d)
  if (totals.length <= topN) return d
  const keep = new Set(totals.slice(0, topN).map((t) => t.category))
  const relabelled = d.map((r) => ({ ...r, category: keep.has(r.category) ? r.category : OTHER }))
  return groupSum(relabelled, (r) => `${r.category === null ? '\u0000NA' : r.category}\u0001${r.period}\u0001${r.periodSort}`,
    (r) => ({ ...r }), (r) => r.value)
}

// ---- order_categories() -----------------------------------------------------------

export function isOrdinalCohort(labels: string[]): boolean {
  const matches = labels.filter((l) => ORDINAL_COHORT_REGEX.test(l)).length
  return labels.length > 0 && matches >= Math.max(2, Math.ceil(labels.length / 2))
}

/**
 * Stack order, bottom of the legend list = bottom of the stack: ordinal
 * cohorts (age groups etc.) low to high, otherwise smallest first so the
 * largest sits at the bottom; a literal "NA" and "Other" always last.
 * `categoriesDesc` must already be in descending-total order.
 */
export function orderCategories(categoriesDesc: string[]): string[] {
  const trailing = [NA_LABEL, OTHER].filter((t) => categoriesDesc.includes(t))
  const nonOther = categoriesDesc.filter((c) => !trailing.includes(c))
  let ordered: string[]
  if (isOrdinalCohort(nonOther)) {
    const leading = (s: string) => Number(ORDINAL_COHORT_REGEX.exec(s)![1])
    const numeric = nonOther.filter((c) => ORDINAL_COHORT_REGEX.test(c))
      .map((c, i) => ({ c, i, n: leading(c) }))
      .sort((a, b) => a.n - b.n || a.i - b.i)
      .map((x) => x.c)
    const rest = nonOther.filter((c) => !ORDINAL_COHORT_REGEX.test(c)).sort(icu.compare)
    ordered = [...numeric, ...rest]
  } else {
    ordered = [...nonOther].reverse()
  }
  return [...ordered, ...trailing]
}

// ---- to_percent_of_total() ---------------------------------------------------------

export function toPercentOfTotal(rows: PlotRow[]): PlotRow[] {
  const totals = new Map<string, number>()
  for (const r of rows) totals.set(r.period, addNa(totals.get(r.period) ?? 0, r.value))
  return rows.map((r) => {
    const t = totals.get(r.period)!
    return { ...r, value: t > 0 ? (100 * r.value) / t : 0 }
  })
}

// ---- build_series_plot_data() ------------------------------------------------------

/**
 * Everything the chart needs for one view. `cols` is the decoded partition
 * for (theme, p.geoLevel).
 */
export function buildPlotData(cols: SeriesFactsColumns, p: ViewParams): PlotData {
  const agg = aggregateSeries(fetchSeriesRows(cols, p), p.granularity, p.isStock, p.level)

  // Suppressed Residual: published series total minus what's visible, only at
  // the top breakdown level - once drilled, the series-wide total would count
  // every other category as "suppressed".
  let residual: AggRow[] = []
  if (agg.length > 0 && p.drill1 == null && !p.level) {
    const totalRows = fetchSeriesRows(cols, p, 'Total')
    if (totalRows.length > 0) {
      // R: fetch_series_published_total() - one summed row per period, then
      // the same aggregation (so a stock series takes the latest month).
      const sums = new Map<string, RawRow>()
      for (const r of totalRows) {
        const k = `${r.year}\u0001${r.quarter}\u0001${r.month}`
        let s = sums.get(k)
        if (!s) {
          s = { entity: 'total', category: 'total', year: r.year, quarter: r.quarter, month: r.month, value: 0 }
          sums.set(k, s)
        }
        s.value = addNa(s.value ?? 0, r.value)
      }
      const published = new Map(aggregateSeries([...sums.values()], p.granularity, p.isStock)
        .map((r) => [r.period, r.value]))
      const visible = new Map<string, { sort: number; total: number }>()
      for (const r of agg) {
        const v = visible.get(r.period) ?? { sort: r.periodSort, total: 0 }
        v.total = addNa(v.total, r.value)
        visible.set(r.period, v)
      }
      for (const [period, v] of visible) {
        const pub = published.get(period)
        if (pub === undefined) continue
        const gap = Math.max(0, pub - v.total)
        if (gap > 0) residual.push({ category: SUPPRESSED_RESIDUAL, period, periodSort: v.sort, value: gap })
      }
    }
  }

  const capped = [...(p.level ? agg : collapseToTopN(agg, p.topN)), ...residual]
  if (capped.length === 0) return { categoryOrder: [], periodOrder: [], rows: [] }

  const periodSeen = new Map<string, number>()
  for (const r of capped) if (!periodSeen.has(r.period)) periodSeen.set(r.period, r.periodSort)
  const periodOrder = [...periodSeen.entries()].sort((a, b) => a[1] - b[1]).map(([period]) => period)

  // R filters category != "Suppressed Residual", which also drops missing
  // categories - they stay in the data but get no legend entry.
  const ranked = categoryTotalsDesc(capped.filter((r) => r.category !== null && r.category !== SUPPRESSED_RESIDUAL))
  const categoryOrder = orderCategories(ranked.map((t) => t.category as string))
  if (residual.length > 0) categoryOrder.push(SUPPRESSED_RESIDUAL)

  const known = new Set(categoryOrder)
  let rows: PlotRow[] = capped.map((r) => ({
    category: r.category !== null && known.has(r.category) ? r.category : null,
    period: r.period, periodSort: r.periodSort, value: r.value
  }))
  if (p.displayAs === 'percent' && !p.level) rows = toPercentOfTotal(rows)
  return { categoryOrder, periodOrder, rows }
}

// ---- web-only ordering (not in the R app) ----------------------------------------------

/**
 * Province/Territory views list provinces west to east (British Columbia
 * first, so it leads the legend and tops the stack) instead of by size. Any
 * other categories ("Other", "not stated", Suppressed Residual) keep their
 * order after the provinces. A display choice layered on top of
 * buildPlotData(), so the R parity tests are unaffected.
 */
export function orderWestToEast(data: PlotData): PlotData {
  const present = new Set(data.categoryOrder)
  const provinces = PROVINCE_ORDER_WEST_TO_EAST.filter((p) => present.has(p))
  const rest = data.categoryOrder.filter((c) => !provinces.includes(c))
  return { ...data, categoryOrder: [...provinces, ...rest] }
}

// ---- list_series_breakdown_values() --------------------------------------------------

/** Drill-down choices: distinct breakdown_1 values, or breakdown_2 values under one breakdown_1. */
export function listBreakdownValues(cols: SeriesFactsColumns, series: string, facet: string,
                                    drill1: string | null = null): string[] {
  const target = drill1 == null ? cols.breakdown_1 : cols.breakdown_2
  const seen = new Set<string>()
  for (let i = 0; i < cols.length; i++) {
    if (cols.series[i] !== series || cols.facet[i] !== facet) continue
    if (drill1 != null && cols.breakdown_1[i] !== drill1) continue
    const v = target[i]
    if (v != null) seen.add(v)
  }
  return [...seen].sort(icu.compare)
}

/** Distinct source tables behind a view, for its citation - within `years` when given. */
export function sourceTableIds(cols: SeriesFactsColumns, series: string, facet?: string,
                               years?: [number, number]): string[] {
  const seen = new Set<string>()
  for (let i = 0; i < cols.length; i++) {
    if (cols.series[i] !== series || (facet !== undefined && cols.facet[i] !== facet)) continue
    const year = cols.period_year[i]
    if (years && (year == null || year < years[0] || year > years[1])) continue
    const id = cols.source_table_id[i]
    if (id != null) seen.add(id)
  }
  return [...seen]
}
