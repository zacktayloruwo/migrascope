// Explorer state and the selector cascade, ported from app.R's observers.
//
// Shiny wires the cascade as chains of observers that fire in an order Shiny
// doesn't guarantee (app.R has long comments about the resulting bugs). Here
// each user action is a method that applies the same rules in a fixed order,
// and everything downstream is a lazily computed $derived value. Differences
// from app.R, both deliberate:
//  - Temporal aggregation and year range reset only when the resolved view
//    (series x facet x geographic level) actually changes, not on every input
//    that touches it - picking a different province keeps your year range.
//  - Drill selections only apply while a breakdown is shown (app.R could
//    filter a "Total" view by a stale drill value and show no data).

import type { SeriesFactsColumns } from '../query/columns'
import { GEO_UNIT_SEP } from '../query/constants'
import { buildDrawPlotData, buildPlotData, isScoreRangeView, orderScoreRanges, orderWestToEast, sourceTableIds, type Granularity, type PlotData,
         type ViewParams } from '../query/plotData'
import { partialPeriods, type PartialPeriod } from '../query/partial'
import { drillableValues } from '../query/drill'
import { THEMES, type Lang } from './i18n'
import type { DefaultView, Meta, SummaryRow } from './meta'

export type GeoLevel = 'national' | 'PT' | 'CMA' | 'CD' | 'CSD'
export const GEO_LEVELS: GeoLevel[] = ['national', 'PT', 'CMA', 'CD', 'CSD']
export const GRANULARITIES: Granularity[] = ['Monthly', 'Quarterly', 'Annual']

/** app.R: geo_level_query_value() - the radio's "national" is series_facts' "National". */
export const geoQuery = (g: GeoLevel): string => (g === 'national' ? 'National' : g)

const icu = new Intl.Collator('en-CA')
const uniqueSorted = (xs: string[]) => [...new Set(xs)].sort(icu.compare)

export class Explorer {
  lang = $state<Lang>('en')
  view = $state<'plot' | 'about'>('plot')
  theme = $state('')
  series = $state('')
  geoLevel = $state<GeoLevel>('national')
  geoUnit = $state('All')
  catLevel = $state('none')
  drill1 = $state('none')
  drill2 = $state('none')
  granularity = $state<Granularity>('Annual')
  years = $state<[number, number]>([2015, 2026])
  displayAs = $state<'absolute' | 'percent'>('absolute')
  topN = $state(10)

  /** Decoded partition for (theme, scope's geo level), and which one it is. */
  cols = $state.raw<SeriesFactsColumns | null>(null)
  colsKey = $state('')

  /** Pre-aggregated first chart per theme (views/<theme>.default.json), shown until the partition loads. */
  defaultViews = $state.raw<Record<string, DefaultView>>({})

  private lastScopeKey = ''

  constructor(readonly meta: Meta) {}

  // ---- what the selectors offer -------------------------------------------------

  // $derived.by keeps the read lazy - `meta` is only assigned once the constructor runs.
  themeRows = $derived.by(() => this.meta.summary.filter((r) => r.theme === this.theme))
  seriesOptions = $derived(uniqueSorted(this.themeRows.map((r) => r.series)))
  seriesRows = $derived(this.themeRows.filter((r) => r.series === this.series))

  /** Geographic levels this series is published at (app.R: setGeoAvailability). */
  geoAvailable = $derived(new Set<GeoLevel>(['national',
    ...this.seriesRows.map((r) => r.geo_level).filter((g) => g !== 'National') as GeoLevel[]]))

  rankRows = $derived(this.seriesRows.filter((r) => r.geo_level === geoQuery(this.geoLevel)))
  facets = $derived(uniqueSorted(this.rankRows.map((r) => r.facet).filter((f) => f !== 'Total')))
  hasTotal = $derived(this.rankRows.some((r) => r.facet === 'Total'))
  /** "None" (= the Total view) is offered when a Total exists, or when there's nothing else. */
  catChoices = $derived(this.hasTotal || this.facets.length === 0 ? ['none', ...this.facets] : this.facets)

  geoUnitChoices = $derived.by(() => {
    if (this.geoLevel === 'national') return { values: ['All'], labels: ['All'] }
    const sourceFacet = this.hasTotal ? 'Total' : this.facets[0]
    const entry = this.meta.geoUnits.find((u) => u.theme === this.theme && u.series === this.series &&
      u.facet === sourceFacet && u.geo_level === this.geoLevel)
    return entry ? { values: entry.values, labels: entry.labels } : { values: ['All'], labels: ['All'] }
  })

  showGeoUnit = $derived(this.geoLevel !== 'national')
  showBreakdown = $derived(this.geoLevel === 'national' || this.geoUnit !== 'All')

  /** The resolved view - app.R: current_scope_raw(). */
  scope = $derived.by((): SummaryRow | null => {
    const geoReal = this.geoLevel !== 'national'
    const facet = (geoReal && this.geoUnit === 'All') || this.catLevel === 'none' ? 'Total' : this.catLevel
    return this.rankRows.find((r) => r.facet === facet) ?? null
  })

  // Express Entry rounds are shown draw by draw only (no monthly/quarterly/annual roll-up).
  granularityChoices = $derived.by((): Granularity[] =>
    this.scope?.draws && this.meta.drawData ? ['Draw'] :
    !this.scope?.has_month ? ['Annual'] : this.scope.quarterly_only ? ['Quarterly', 'Annual'] : GRANULARITIES)

  private plotGranularity = $derived<Granularity>(
    this.granularityChoices.includes(this.granularity) ? this.granularity : this.granularityChoices.at(-1) ?? 'Annual')

  /**
   * The years this view can show. Monthly and Quarterly start at the first
   * year with monthly data when earlier years are annual only.
   */
  yearBounds = $derived.by((): [number, number] => {
    const s = this.scope
    if (!s) return this.years
    const first = this.plotGranularity !== 'Annual' && s.month_min_year ? s.month_min_year : s.min_year
    return [first, s.max_year]
  })

  /** The chosen years, within what this view can show (`years` itself is kept for Annual). */
  plotYears = $derived<[number, number]>([
    Math.min(Math.max(this.years[0], this.yearBounds[0]), this.yearBounds[1]),
    Math.max(Math.min(this.years[1], this.yearBounds[1]), this.yearBounds[0])
  ])

  /** Percentage of a single unbroken bar is always 100% (app.R: setPercentAllowed). */
  percentAllowed = $derived(this.scope?.measure !== 'level' && !(this.scope?.facet === 'Total' &&
    (this.geoLevel === 'national' || this.geoUnit !== 'All')))

  partitionKey = $derived(this.scope ? `${this.theme}/${this.scope.geo_level}` : '')
  colsReady = $derived(this.cols !== null && this.colsKey === this.partitionKey)

  private catRow = $derived(this.rankRows.find((r) => r.facet === this.catLevel))

  drill1Values = $derived.by(() => {
    if (!this.colsReady || this.catLevel === 'none' || !this.catRow?.has_breakdown_2) return []
    // only categories that split further - no dead-end drills (see query/drill.ts)
    return drillableValues(this.cols!, this.series, this.catLevel)
  })
  drill1Needed = $derived(this.showBreakdown && this.drill1Values.length > 0)

  drill2Values = $derived.by(() => {
    if (!this.drill1Needed || this.drill1 === 'none' || !this.catRow?.has_breakdown_3) return []
    return drillableValues(this.cols!, this.series, this.catLevel, this.drill1)
  })
  drill2Needed = $derived(this.drill2Values.length > 0)

  // ---- what gets plotted ------------------------------------------------------------

  params = $derived.by((): ViewParams | null => {
    const s = this.scope
    if (!s) return null
    const breakdown = s.facet !== 'Total'
    const drill1 = breakdown && this.drill1Needed && this.drill1 !== 'none' ? this.drill1 : null
    const drill2 = drill1 && this.drill2Needed && this.drill2 !== 'none' ? this.drill2 : null
    return {
      series: this.series, facet: s.facet, geoLevel: s.geo_level, geoDepth: s.geo_depth,
      granularity: this.plotGranularity,
      years: this.plotYears, isStock: s.is_stock, topN: this.topN,
      displayAs: this.percentAllowed ? this.displayAs : 'absolute',
      geoUnitPrefix: this.geoLevel !== 'national' && this.geoUnit !== 'All' ? this.geoUnit.split(GEO_UNIT_SEP) : [],
      drill1, drill2,
      level: s.measure === 'level'
    }
  })

  /** Every province/territory as its own category: shown west to east rather than by size. */
  isProvinceView = $derived(this.params?.geoLevel === 'PT' && this.params.facet === 'Total' &&
    this.params.geoUnitPrefix.length === 0)

  plotData = $derived.by((): PlotData | null => {
    const p = this.params
    const data = p?.granularity === 'Draw' && this.meta.drawData ? buildDrawPlotData(this.meta.drawData, p)
      : this.colsReady && p ? buildPlotData(this.cols!, p) : this.pendingDefault()
    if (!data) return data
    if (this.isProvinceView) return orderWestToEast(data)
    return isScoreRangeView(data) ? orderScoreRanges(data) : data
  })

  /** The theme's pre-aggregated view, if the current inputs are exactly the ones it was built for. */
  private pendingDefault(): PlotData | null {
    const v = this.defaultViews[this.theme]
    const p = this.params
    if (!v || !p) return null
    const same = v.series === p.series && v.facet === p.facet && v.geo_level === p.geoLevel &&
      v.granularity === p.granularity && v.years[0] === p.years[0] && v.years[1] === p.years[1] &&
      v.top_n === p.topN && v.display_as === p.displayAs && p.geoUnitPrefix.length === 0 && !p.drill1
    if (!same) return null
    return {
      categoryOrder: v.category_order, periodOrder: v.period_order,
      rows: v.rows.map((r) => ({ category: r.category, period: r.period, periodSort: r.period_sort, value: r.value }))
    }
  }

  /** Plotted periods with incomplete data (e.g. 2026 to July): asterisked and described in the Note. */
  partial = $derived.by((): PartialPeriod[] =>
    this.colsReady && this.params ? partialPeriods(this.cols!, this.params, this.meta.dataThrough) : [])

  /**
   * Source tables behind the current view (app.R: series_source_table_ids()):
   * the facet's tables for the plotted years, plus the Total's when the chart
   * computes a Suppressed Residual from it (a breakdown that isn't drilled into).
   */
  sourceIds = $derived.by(() => {
    if (!this.colsReady || !this.scope || !this.params) return { view: [] as string[], series: [] as string[] }
    const p = this.params
    const view = sourceTableIds(this.cols!, this.series, p.facet, p.years)
    const total = p.facet !== 'Total' && p.drill1 == null ? sourceTableIds(this.cols!, this.series, 'Total', p.years) : []
    return { view: [...new Set([...view, ...total])], series: sourceTableIds(this.cols!, this.series) }
  })

  // ---- actions (app.R's observers, in a fixed order) ----------------------------------

  /** app.R input$theme observer: pick the series with the widest coverage. */
  setTheme(theme: string) {
    this.theme = theme
    const scored = this.seriesOptions.map((series) => {
      const rows = this.themeRows.filter((r) => r.series === series)
      return {
        series,
        nScope: rows.length,
        maxGeoDepth: Math.max(...rows.map((r) => r.geo_depth)),
        anyBreakdown: rows.some((r) => r.has_breakdown_2 || r.has_breakdown_3) ? 1 : 0,
        anyMonth: rows.some((r) => r.has_month) ? 1 : 0,
        yearSpan: Math.max(...rows.map((r) => r.max_year)) - Math.min(...rows.map((r) => r.min_year))
      }
    }).sort((a, b) => b.nScope - a.nScope || b.maxGeoDepth - a.maxGeoDepth || b.anyBreakdown - a.anyBreakdown ||
      b.anyMonth - a.anyMonth || b.yearSpan - a.yearSpan || (a.series < b.series ? -1 : a.series > b.series ? 1 : 0))
    this.setSeries(scored[0]?.series ?? '')
  }

  /** app.R input$series observer: back to National, default breakdown. */
  setSeries(series: string) {
    this.series = series
    this.geoLevel = 'national'
    this.geoUnit = 'All'
    this.catLevel = this.catChoices[0] ?? 'none'
    this.drill1 = 'none'
    this.drill2 = 'none'
    this.afterScopeChange()
  }

  /** app.R input$geo_level observer. */
  setGeoLevel(level: GeoLevel) {
    if (!this.geoAvailable.has(level)) return
    this.geoLevel = level
    if (level === 'national') {
      this.geoUnit = 'All'
    } else {
      const units = this.geoUnitChoices.values
      this.geoUnit = this.hasTotal || units.length < 2 ? 'All' : units[1]
    }
    if (!this.facets.includes(this.catLevel)) this.catLevel = this.catChoices[0] ?? 'none'
    this.afterScopeChange()
  }

  setGeoUnit(unit: string) {
    this.geoUnit = this.geoUnitChoices.values.includes(unit) ? unit : 'All'
    this.afterScopeChange()
  }

  /** app.R input$cat_level observer: a place-level view without this breakdown falls back to All. */
  setCatLevel(cat: string) {
    this.catLevel = cat
    if (this.geoUnit !== 'All') {
      const facet = cat === 'none' ? 'Total' : cat
      if (!this.rankRows.some((r) => r.facet === facet)) this.geoUnit = 'All'
    }
    this.afterScopeChange()
  }

  setDrill1(value: string) {
    this.drill1 = value
    this.drill2 = 'none'
  }

  setDrill2(value: string) {
    this.drill2 = value
  }

  setYears(from: number, to: number) {
    const s = this.scope
    if (!s) return
    const a = Math.max(s.min_year, Math.min(from, to))
    const b = Math.min(s.max_year, Math.max(from, to))
    this.years = [a, b]
  }

  /** Once drill choices are known (they need the partition), drop selections that no longer exist. */
  validateDrills() {
    if (!this.colsReady) return
    if (this.drill1 !== 'none' && !this.drill1Values.includes(this.drill1)) this.drill1 = 'none'
    if (this.drill2 !== 'none' && !this.drill2Values.includes(this.drill2)) this.drill2 = 'none'
  }

  /** app.R: observeEvent(current_scope_raw()) and the setPercentAllowed observer. */
  private afterScopeChange() {
    const s = this.scope
    const key = s ? `${s.theme}|${s.series}|${s.facet}|${s.geo_level}` : ''
    if (s && key !== this.lastScopeKey) {
      this.granularity = this.granularityChoices[this.granularityChoices.length - 1]
      this.years = [s.min_year, s.max_year]
    }
    this.lastScopeKey = key
    if (!this.percentAllowed && this.displayAs === 'percent') this.displayAs = 'absolute'
  }

  // ---- URL state ------------------------------------------------------------------------

  /** Every view is a link: the full state, compactly, in the URL hash. */
  toHash(): string {
    const p = new URLSearchParams()
    p.set('lang', this.lang)
    if (this.view === 'about') p.set('view', 'about')
    p.set('t', this.theme)
    p.set('s', this.series)
    if (this.geoLevel !== 'national') p.set('g', this.geoLevel)
    if (this.geoUnit !== 'All') p.set('u', this.geoUnit)
    if (this.catLevel !== 'none') p.set('f', this.catLevel)
    if (this.drill1 !== 'none') p.set('d1', this.drill1)
    if (this.drill2 !== 'none') p.set('d2', this.drill2)
    p.set('gran', this.granularity[0])
    p.set('y', `${this.years[0]}-${this.years[1]}`)
    if (this.displayAs === 'percent') p.set('pct', '1')
    if (this.topN !== 10) p.set('n', String(this.topN))
    return `#${p.toString()}`
  }

  /** Restore a hash, applying each value through the same rules a click would; invalid values fall back. */
  fromHash(hash: string) {
    const p = new URLSearchParams(hash.replace(/^#/, ''))
    this.lang = p.get('lang') === 'fr' ? 'fr' : 'en'
    this.view = p.get('view') === 'about' ? 'about' : 'plot'
    const theme = THEMES.some((t) => t.id === p.get('t')) && this.meta.summary.some((r) => r.theme === p.get('t'))
      ? p.get('t')! : THEMES.find((t) => this.meta.summary.some((r) => r.theme === t.id))!.id
    this.setTheme(theme)
    const series = p.get('s')
    if (series && this.seriesOptions.includes(series) && series !== this.series) this.setSeries(series)
    const g = p.get('g') as GeoLevel | null
    if (g && GEO_LEVELS.includes(g)) this.setGeoLevel(g)
    const u = p.get('u')
    if (u) this.setGeoUnit(u)
    const f = p.get('f')
    if (f && this.catChoices.includes(f)) this.setCatLevel(f)
    this.drill1 = p.get('d1') ?? 'none' // checked by validateDrills() once the data is in
    this.drill2 = p.get('d2') ?? 'none'
    const gran = GRANULARITIES.find((x) => x[0] === p.get('gran'))
    if (gran && this.granularityChoices.includes(gran)) this.granularity = gran
    const y = p.get('y')?.match(/^(\d{4})-(\d{4})$/)
    if (y) this.setYears(Number(y[1]), Number(y[2]))
    // Settings the link leaves out go back to their defaults rather than
    // keeping whatever this tab last showed.
    this.displayAs = p.get('pct') === '1' && this.percentAllowed ? 'percent' : 'absolute'
    const n = Number(p.get('n'))
    this.topN = Number.isInteger(n) && n >= 2 && n <= 15 ? n : 10
  }
}
