<script lang="ts">
  // Stacked bar chart of one view's PlotData with ECharts. Stack order
  // follows the R app: the first category in categoryOrder sits at the top of
  // each bar, the last (largest, then Other / NA / Suppressed Residual) at the
  // bottom.
  import * as echarts from 'echarts/core'
  import { BarChart } from 'echarts/charts'
  import { AriaComponent, GridComponent, LegendComponent, TooltipComponent } from 'echarts/components'
  import { SVGRenderer } from 'echarts/renderers'
  import type { PlotData } from '../query/plotData'
  import { formatNumber, formatPercent, type I18n, type Lang } from '../lib/i18n'
  import { NA_LABEL, OTHER, SUPPRESSED_RESIDUAL } from '../query/constants'

  echarts.use([BarChart, GridComponent, TooltipComponent, LegendComponent, AriaComponent, SVGRenderer])

  let { data, lang, i18n, granularity, percent }: {
    data: PlotData; lang: Lang; i18n: I18n; granularity: string; percent: boolean
  } = $props()

  /**
   * Category colours (docs/wasm-port-plan.md, 4.11). The first four were
   * checked for colour-blind safety; the rest extend the set for top-N up to
   * 15 and still need that check.
   */
  const PALETTE = ['#2348C4', '#5BC0EB', '#E8506A', '#FFB627', '#6C3FB4', '#2E9E6B', '#B4621B', '#9DB2FF',
                   '#C2185B', '#7A9A01', '#0E6E8C', '#E89BB0', '#8C6D1F', '#4C5BA8', '#3FB8AF']
  const FIXED: Record<string, string> = { [OTHER]: '#8E96A3', [NA_LABEL]: '#D5D9DF', [SUPPRESSED_RESIDUAL]: '#E3E7EC' }
  const NULL_KEY = '\u0000NA'

  const escapeHtml = (s: string) => s.replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`)
  const fmt = (v: number) => (percent ? formatPercent(v, lang) : formatNumber(v, lang))

  /** Legend entries in legend order (top of the stack first), shared by the chart and the HTML legend. */
  const legend = $derived.by(() => {
    const hasNull = data.rows.some((r) => r.category === null)
    const stackOrder = [...(hasNull ? [NULL_KEY] : []), ...[...data.categoryOrder].reverse()]
    const ranked = stackOrder.filter((c) => c !== NULL_KEY && !(c in FIXED))
    const colour = (c: string) => (c === NULL_KEY ? FIXED[NA_LABEL] : FIXED[c] ?? PALETTE[ranked.indexOf(c) % PALETTE.length])
    const single = data.categoryOrder.length <= 1 && !hasNull
    const name = (c: string) => (c === NULL_KEY ? i18n.category(null, lang) : i18n.category(c, lang))
    const items = [...data.categoryOrder, ...(hasNull ? [NULL_KEY] : [])]
      .map((c) => ({ key: c, name: name(c), colour: single ? '#2348C4' : colour(c), hatched: c === SUPPRESSED_RESIDUAL }))
    return { stackOrder, items, single, colour, name, hasNull }
  })

  /** Series the reader has switched off by clicking the legend. */
  let hidden = $state(new Set<string>())
  $effect(() => { void data; hidden = new Set() }) // a new view starts with everything shown

  function toggle(name: string) {
    const next = new Set(hidden)
    if (next.has(name)) next.delete(name)
    else next.add(name)
    hidden = next
  }

  const option = $derived.by(() => {
    const { periodOrder, rows } = data
    // Bottom of the stack first; rows with a missing category go at the very bottom.
    const { stackOrder, single, colour, name } = legend
    const periodIndex = new Map(periodOrder.map((p, i) => [p, i]))
    const values = new Map(stackOrder.map((c) => [c, new Array<number | null>(periodOrder.length).fill(null)]))
    for (const r of rows) {
      const arr = values.get(r.category ?? NULL_KEY)
      const i = periodIndex.get(r.period)
      if (arr && i !== undefined) arr[i] = (arr[i] ?? 0) + r.value
    }

    return {
      animationDuration: 300,
      aria: { enabled: true, decal: { show: false } },
      grid: { left: 8, right: 16, top: 16, bottom: 8, containLabel: true },
      tooltip: {
        trigger: 'axis', axisPointer: { type: 'shadow' }, confine: true,
        formatter: (items: { seriesName: string; value: number | null; color: string; axisValueLabel: string }[]) => {
          const shown = items.filter((p) => p.value != null && p.value !== 0).reverse()
          const total = shown.reduce((a, p) => a + (p.value ?? 0), 0)
          const lines = shown.map((p) =>
            `<div style="display:flex;justify-content:space-between;gap:16px"><span>` +
            `<span style="display:inline-block;width:10px;height:10px;border-radius:2px;background:${p.color};margin-right:6px"></span>` +
            `${escapeHtml(p.seriesName)}</span><strong>${fmt(p.value ?? 0)}</strong></div>`)
          const head = `<div style="font-weight:700;margin-bottom:4px">${escapeHtml(items[0]?.axisValueLabel ?? '')}` +
            (shown.length > 1 && !percent ? ` · ${fmt(total)}` : '') + '</div>'
          return head + lines.join('')
        }
      },
      // Drawn as HTML below the chart (wraps on phones, readable by screen
      // readers); this hidden legend only carries which series are switched off.
      legend: {
        show: false, data: legend.items.map((i) => i.name),
        selected: Object.fromEntries(legend.items.map((i) => [i.name, !hidden.has(i.name)]))
      },
      xAxis: {
        type: 'category', data: periodOrder,
        axisLabel: {
          rotate: periodOrder.length > 12 ? 45 : 0, color: '#3A4558',
          interval: granularity === 'Monthly' ? (i: number) => i % 3 === 0 : 'auto'
        },
        axisTick: { alignWithLabel: true }
      },
      yAxis: {
        type: 'value', max: percent ? 100 : undefined,
        axisLabel: { color: '#3A4558', formatter: (v: number) => (percent ? `${v}%` : formatNumber(v, lang)) },
        splitLine: { lineStyle: { color: '#E6EAEE' } }
      },
      series: stackOrder.map((c) => ({
        name: name(c),
        type: 'bar', stack: 'total', barMaxWidth: 48,
        emphasis: { focus: 'series' },
        data: values.get(c),
        itemStyle: {
          color: single ? '#2348C4' : colour(c),
          // Suppressed Residual is drawn hatched, not just grey, so it reads as "missing" rather than a category.
          decal: c === SUPPRESSED_RESIDUAL
            ? { symbol: 'rect', symbolSize: 1, color: '#8E96A3', dashArrayX: [1, 0], dashArrayY: [2, 4], rotation: -Math.PI / 4 }
            : undefined
        }
      }))
    }
  })

  let el: HTMLDivElement
  let chart: echarts.ECharts | undefined

  $effect(() => {
    chart = echarts.init(el, undefined, { renderer: 'svg' })
    const ro = new ResizeObserver(() => chart?.resize())
    ro.observe(el)
    return () => { ro.disconnect(); chart?.dispose(); chart = undefined }
  })

  $effect(() => {
    // notMerge: a new view replaces the old series entirely.
    chart?.setOption(option as echarts.EChartsCoreOption, { notMerge: true })
  })
</script>

<div class="chart" bind:this={el}></div>
{#if !legend.single}
  <ul class="legend" aria-label={lang === 'fr' ? 'Légende (cliquer pour masquer une catégorie)' : 'Legend (click to hide a category)'}>
    {#each legend.items as item (item.key)}
      <li>
        <button type="button" aria-pressed={!hidden.has(item.name)} onclick={() => toggle(item.name)}>
          <span class="swatch" class:hatched={item.hatched} style:background-color={item.colour}></span>{item.name}
        </button>
      </li>
    {/each}
  </ul>
{/if}

<style>
  .chart { width: 100%; height: clamp(300px, 55vh, 540px); }
  .legend { list-style: none; margin: 0; padding: 0; display: flex; flex-wrap: wrap; gap: 4px 6px; justify-content: center; }
  .legend button {
    display: inline-flex; align-items: center; gap: 8px; border: 0; background: transparent; cursor: pointer;
    padding: 6px 8px; border-radius: 6px; font-size: 14px; color: var(--ink); min-height: 36px;
  }
  .legend button:hover { background: var(--primary-tint); }
  .legend button[aria-pressed='false'] { color: #8A93A2; text-decoration: line-through; }
  .legend button[aria-pressed='false'] .swatch { opacity: 0.35; }
  .swatch { width: 14px; height: 14px; border-radius: 3px; flex: none; }
  .swatch.hatched { background-image: repeating-linear-gradient(135deg, #8E96A3 0 2px, transparent 2px 6px); }
</style>
