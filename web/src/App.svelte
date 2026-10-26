<script lang="ts">
  import { DataStore } from './query/loader'
  import { loadMeta, localizeSource, type DefaultView, type Meta } from './lib/meta'
  import { Explorer } from './lib/state.svelte'
  import { I18n, formatDate, formatMonth, themeLabel } from './lib/i18n'
  import { buildCsv, downloadBlob, downloadText, slug } from './lib/csv'
  import { renderSlide } from './lib/slide'
  import Header from './components/Header.svelte'
  import Controls from './components/Controls.svelte'
  import Chart from './components/Chart.svelte'
  import Citation from './components/Citation.svelte'

  const store = new DataStore(`${import.meta.env.BASE_URL}data/`)

  let app = $state<Explorer | null>(null)
  let i18n = $state<I18n | null>(null)
  let loadError = $state<string | null>(null)
  let partitionError = $state<string | null>(null)

  loadMeta(store)
    .then((meta: Meta) => {
      const explorer = new Explorer(meta)
      explorer.fromHash(location.hash)
      i18n = new I18n(meta)
      app = explorer
    })
    .catch((e) => (loadError = String(e?.message ?? e)))

  // Load the (theme, geo level) partition the current view needs.
  $effect(() => {
    if (!app || !app.partitionKey) return
    const key = app.partitionKey
    const [theme, geoLevel] = key.split('/')
    partitionError = null
    store.loadPartition(theme, geoLevel)
      .then((cols) => {
        if (app && app.partitionKey === key) { app.cols = cols; app.colsKey = key }
      })
      .catch((e) => { if (app?.partitionKey === key) partitionError = String(e?.message ?? e) })
    // Most people go from National to Province/Territory next.
    if (geoLevel === 'National' && app.geoAvailable.has('PT')) store.prefetch(theme, 'PT')
  })

  $effect(() => { app?.validateDrills() })

  // The theme's pre-aggregated first chart: a few KB, so it shows before the partition decodes.
  $effect(() => {
    if (!app || !app.theme || app.defaultViews[app.theme]) return
    const theme = app.theme
    store.json<DefaultView>(`views/${theme}.default.json`)
      .then((v) => { if (app) app.defaultViews = { ...app.defaultViews, [theme]: v } })
      .catch(() => {}) // optional: the live query covers it
  })

  let chartCard = $state<HTMLElement>()
  let fullscreen = $state(false)
  /** Categories hidden via the chart legend - shared with the CSV export. */
  let hiddenCategories = $state(new Set<string>())

  /**
   * In a drilled view, rows with no category value are the drilled-into
   * category itself, with no finer breakdown in the source - label them that
   * way rather than "NA". Dead-end drills aren't offered (query/drill.ts), so
   * this is a safety net.
   */
  const nullLabel = $derived.by(() => {
    const parent = app?.params?.drill2 ?? app?.params?.drill1
    if (!app || !i18n || !parent) return undefined
    return `${i18n.category(parent, app.lang)} ${app.lang === 'fr' ? '(aucune ventilation)' : '(no further breakdown)'}`
  })
  const categoryName = (c: string | null) => (c === null && nullLabel ? nullLabel : i18n!.category(c, app!.lang))

  /** Source records behind the current view (as Citation.svelte picks them). */
  const sourceTables = $derived.by(() => {
    if (!app) return []
    const ids = [...new Set(app.sourceIds.view.length ? app.sourceIds.view : app.sourceIds.series)]
    return ids.map((id) => app!.meta.sources.find((s) => id.includes(`/${s.hash}__`)))
      .filter((s) => s !== undefined).map((s) => localizeSource(s, app!.lang))
  })
  /** IRCC/IRB's suppression note - Statistics Canada's estimates aren't suppressed. */
  const suppressed = $derived(!sourceTables.length || sourceTables.some((s) => s.portal !== 'statcan'))

  /** Download file name (without extension) describing the current view. */
  function fileBase(): string {
    const p = app!.params!
    return slug(['migrascope', themeLabel(app!.theme, 'en'), app!.series,
      p.facet === 'Total' ? '' : p.facet, p.drill1 ?? '', p.drill2 ?? '',
      p.geoUnitPrefix.at(-1) ?? (p.geoLevel === 'National' ? '' : p.geoLevel),
      p.granularity, p.displayAs === 'percent' ? 'percent' : '', `${p.years[0]}-${p.years[1]}`])
  }

  /** Download what the chart currently shows as CSV. */
  function exportCsv() {
    if (!app || !i18n || !app.plotData || !app.params) return
    const l = app.lang
    const data = app.plotData
    const hasNull = data.rows.some((r) => r.category === null)
    const columns = [...data.categoryOrder, ...(hasNull ? [null] : [])]
      .filter((c) => !hiddenCategories.has(categoryName(c)))
    const percent = app.params.displayAs === 'percent'
    const notes = [
      title + (percent ? (l === 'fr' ? ' (pourcentage du total)' : ' (percentage of total)') : ''),
      ...(partialNote ? [`* ${partialNote}`] : []),
      ...(suppressed ? [i18n.t('suppression_note', l)] : []),
      ...sourceTables.map((s) => `${l === 'fr' ? 'Source :' : 'Source:'} ${s!.agency}, "${s!.table_name}", ${s!.url}`),
      `${l === 'fr' ? 'Téléchargé de MigraScope le' : 'Downloaded from MigraScope on'} ${new Date().toISOString().slice(0, 10)}${l === 'fr' ? ' :' : ':'} ${location.href}`
    ]
    const csv = buildCsv(data, {
      columns,
      header: categoryName,
      periodLabel: l === 'fr' ? 'Période' : 'Period',
      percent,
      notes
    })
    downloadText(`${fileBase()}.csv`, csv)
  }

  let chartRef = $state<{ renderImage: (w: number, h: number) => Promise<string> }>()
  let exportingPng = $state(false)

  /** Download the chart as a 16:9 slide (PNG) with title, notes, sources and the app's address. */
  async function exportPng() {
    if (!app || !i18n || !app.params || !chartRef || exportingPng) return
    const l = app.lang
    const p = app.params
    const gran = i18n.t(({ Monthly: 'monthly', Quarterly: 'quarterly', Annual: 'annual' } as Record<string, string>)[p.granularity], l)
    const years = p.years[0] === p.years[1] ? `${p.years[0]}` : `${p.years[0]}–${p.years[1]}`
    const subtitle = [`${gran}, ${years}`, ...(p.displayAs === 'percent' ? [i18n.t('percentage_total', l)] : [])].join(' · ')
    const agency = [...new Set(sourceTables.map((s) => s!.agency))].join(' / ')
    const sources = sourceTables.length
      ? i18n.t('citation_source', l) + agency +
        i18n.t(sourceTables[0]!.portal === 'statcan' ? 'citation_portal_statcan' : 'citation_portal', l) +
        sourceTables.map((s) => `“${s!.table_name}”${i18n!.t('citation_last_updated', l, s!.updated_at)}`)
          .join(l === 'fr' ? ' ; ' : '; ') + '.'
      : ''
    // The suppression note only matters when the chart shows a Suppressed Residual.
    const residual = app.plotData?.rows.some((r) => r.category === 'Suppressed Residual') &&
      !hiddenCategories.has(i18n.category('Suppressed Residual', l))
    const notes = [...(partialNote ? [`* ${partialNote}`] : []),
      ...(residual ? [i18n.t('suppression_note', l)] : []), ...(sources ? [sources] : [])]
    const url = new URL('.', location.href).href.replace(/^https?:\/\//, '').replace(/\/$/, '')
    exportingPng = true
    try {
      const png = await renderSlide({ title, subtitle, notes, leadNote: !!partialNote, url },
                                    (w, h) => chartRef!.renderImage(w, h))
      downloadBlob(`${fileBase()}.png`, png)
    } finally {
      exportingPng = false
    }
  }
  $effect(() => {
    const onChange = () => (fullscreen = document.fullscreenElement === chartCard)
    document.addEventListener('fullscreenchange', onChange)
    return () => document.removeEventListener('fullscreenchange', onChange)
  })
  function toggleFullscreen() {
    if (document.fullscreenElement) document.exitFullscreen()
    else chartCard?.requestFullscreen?.()
  }

  // Keep the URL in step with the view, so it can be shared or bookmarked.
  $effect(() => {
    if (!app) return
    const hash = app.toHash()
    if (hash !== location.hash) history.replaceState(null, '', hash)
  })
  $effect(() => {
    const onHash = () => { if (app && location.hash !== app.toHash()) app.fromHash(location.hash) }
    window.addEventListener('hashchange', onHash)
    return () => window.removeEventListener('hashchange', onHash)
  })
  $effect(() => { if (app) document.documentElement.lang = app.lang })

  /**
   * Keep each About heading in the same column as the text under it. Chrome
   * ignores break-after: avoid inside CSS columns, so a heading could end a
   * column with its text at the top of the next. Each heading is wrapped with
   * the paragraph that follows (or, for a list, just its first item, so long
   * lists can still flow across columns) in a block columns can't split.
   */
  function keepHeadingsWithText(html: string): string {
    const doc = new DOMParser().parseFromString(`<div>${html}</div>`, 'text/html')
    const root = doc.body.firstElementChild!
    for (const heading of [...root.querySelectorAll('h3, h4')]) {
      const next = heading.nextElementSibling
      const keep = doc.createElement('div')
      keep.className = 'keep'
      heading.before(keep)
      keep.append(heading)
      if (!next) continue
      if ((next.tagName === 'UL' || next.tagName === 'OL') && next.firstElementChild) {
        const lead = doc.createElement(next.tagName.toLowerCase())
        lead.className = 'lead'
        lead.append(next.firstElementChild)
        keep.append(lead)
      } else {
        keep.append(next)
      }
    }
    return root.innerHTML
  }
  const aboutHtml = $derived(app && i18n ? keepHeadingsWithText(app.meta.aboutHtml[app.lang]) : '')

  /**
   * The Note's first sentence when some plotted periods are incomplete, e.g.
   * "* Partial periods: 2026 covers January–July." - the asterisk matches the
   * one the chart draws above those bars. Stock
   * series show a single month's snapshot, so they name that month instead.
   */
  const partialNote = $derived.by(() => {
    if (!app || !app.partial.length) return ''
    const l = app.lang
    const month = (m: number) => new Intl.DateTimeFormat(l === 'fr' ? 'fr-CA' : 'en-CA', { month: 'long' })
      .format(new Date(2000, m - 1, 1))
    const stock = app.scope?.is_stock
    const parts = app.partial.map((p) => {
      if (!p.months) {
        return l === 'fr' ? `${p.period} ne comprend que les données publiées à ce jour` : `${p.period} includes only data published to date`
      }
      const [a, b] = p.months
      if (stock) {
        return l === 'fr' ? `${p.period} présente ${month(b)}, le dernier mois disponible` : `${p.period} shows ${month(b)}, the latest month available`
      }
      if (a === b) return l === 'fr' ? `${p.period} couvre ${month(a)} seulement` : `${p.period} covers ${month(a)} only`
      return l === 'fr' ? `${p.period} couvre ${month(a)} à ${month(b)}` : `${p.period} covers ${month(a)}–${month(b)}`
    })
    const lead = l === 'fr' ? 'Périodes partielles : ' : 'Partial periods: '
    return `${lead}${parts.join(l === 'fr' ? ' ; ' : '; ')}.`
  })

  /** app.R: output$plot_title */
  const title = $derived.by(() => {
    if (!app || !i18n || !app.scope || !app.params) return ''
    const l = app.lang
    const parts = [themeLabel(app.theme, l), i18n.translate(app.series, 'series', l)]
    if (app.scope.facet !== 'Total') parts.push(i18n.translate(app.scope.facet, 'facet', l))
    if (app.params.drill1) parts.push(i18n.category(app.params.drill1, l))
    if (app.params.drill2) parts.push(i18n.category(app.params.drill2, l))
    let t = parts.join(' → ')
    if (app.params.geoUnitPrefix.length) t += ` — ${app.params.geoUnitPrefix[app.params.geoUnitPrefix.length - 1]}`
    if (app.scope.is_stock) t += ` ${i18n.t('stock_suffix', l)}`
    return t
  })
</script>

{#if loadError}
  <main class="page"><p class="message" role="alert">Couldn’t load the data: {loadError}</p></main>
{:else if !app || !i18n}
  <main class="page"><p class="message" aria-live="polite">Loading…</p></main>
{:else}
  <Header {app} {i18n} />
  <main class="page">
    {#if app.view === 'about'}
      <article class="card about">
        <h1>{i18n.t('about_page_title', app.lang)}</h1>
        <!-- Rendered at build time from app/ABOUT*.md, which is part of this repo. -->
        <div class="about-text">{@html aboutHtml}</div>
        {#if app.meta.dataPulled}
          <p class="pulled">
            {#if app.lang === 'fr'}
              Données téléchargées du Portail du gouvernement ouvert le <strong>{formatDate(app.meta.dataPulled, 'fr')}</strong>;
              elles couvrent la période jusqu’à <strong>{formatMonth(app.meta.dataThrough, 'fr')}</strong>.
            {:else}
              Data last pulled from the Open Government Portal on <strong>{formatDate(app.meta.dataPulled, 'en')}</strong>,
              covering up to <strong>{formatMonth(app.meta.dataThrough, 'en')}</strong>.
            {/if}
          </p>
        {/if}
      </article>
    {:else}
      <Controls {app} {i18n} />
      <section class="card chart-card" class:fullscreen aria-labelledby="chart-title" bind:this={chartCard}>
        <div class="chart-head">
          <h1 id="chart-title">{title}</h1>
          <div class="chart-actions">
          {#if app.plotData?.rows.length}
            <button type="button" class="icon-button" onclick={exportCsv}
                    aria-label={app.lang === 'fr' ? 'Télécharger les données affichées (CSV)' : 'Download the data shown (CSV)'}
                    title={app.lang === 'fr' ? 'Télécharger les données affichées (CSV)' : 'Download the data shown (CSV)'}>
              <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"
                   stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
                <path d="M12 4v12" /><path d="m7 11 5 5 5-5" /><path d="M5 20h14" />
              </svg>
            </button>
          {/if}
          {#if app.plotData?.rows.length}
            <button type="button" class="icon-button" onclick={exportPng} disabled={exportingPng}
                    aria-label={app.lang === 'fr' ? 'Télécharger le graphique en diapositive 16:9 (PNG)' : 'Download the chart as a 16:9 slide (PNG)'}
                    title={app.lang === 'fr' ? 'Télécharger le graphique en diapositive 16:9 (PNG)' : 'Download the chart as a 16:9 slide (PNG)'}>
              <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"
                   stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
                <rect x="3" y="3" width="18" height="18" rx="2" /><circle cx="9" cy="9" r="2" /><path d="m21 15-3.1-3.1a2 2 0 0 0-2.8 0L6 21" />
              </svg>
            </button>
          {/if}
          {#if document.fullscreenEnabled}
            <button type="button" class="icon-button" onclick={toggleFullscreen}
                    aria-label={fullscreen ? (app.lang === 'fr' ? 'Quitter le plein écran' : 'Exit full screen')
                                           : (app.lang === 'fr' ? 'Plein écran' : 'Full screen')}>
              <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"
                   stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
                {#if fullscreen}<path d="M8 3v3a2 2 0 0 1-2 2H3m18 0h-3a2 2 0 0 1-2-2V3m0 18v-3a2 2 0 0 1 2-2h3M3 16h3a2 2 0 0 1 2 2v3" />
                {:else}<path d="M8 3H5a2 2 0 0 0-2 2v3m18 0V5a2 2 0 0 0-2-2h-3m0 18h3a2 2 0 0 0 2-2v-3M3 16v3a2 2 0 0 0 2 2h3" />{/if}
              </svg>
            </button>
          {/if}
          </div>
        </div>
        {#if partitionError}
          <p class="message" role="alert">{partitionError}</p>
        {:else if !app.plotData}
          <p class="message" aria-live="polite">{app.lang === 'fr' ? 'Chargement des données…' : 'Loading data…'}</p>
        {:else if app.plotData.rows.length === 0}
          <p class="message">{i18n.t('no_data', app.lang)}</p>
        {:else}
          <Chart data={app.plotData} lang={app.lang} {i18n} granularity={app.params?.granularity ?? 'Annual'}
                 percent={app.params?.displayAs === 'percent'} partial={app.partial.map((p) => p.period)}
                 bind:hidden={hiddenCategories} {nullLabel} bind:this={chartRef} />
        {/if}
        <p class="note">
          {#if partialNote}<strong class="partial-note"><span class="partial-mark" aria-hidden="true">*</span>{partialNote}</strong>{/if}
          {#if suppressed}{i18n.t('suppression_note', app.lang)}{/if}
        </p>
        <Citation viewIds={app.sourceIds.view} seriesIds={app.sourceIds.series} sources={app.meta.sources}
                  lang={app.lang} {i18n} />
      </section>
    {/if}
  </main>
{/if}

<style>
  .page { max-width: 1440px; margin: 0 auto; padding: 12px 20px 32px; display: flex; flex-direction: column; gap: 12px; }
  .card { background: var(--surface); border: 1px solid var(--border); border-radius: var(--radius); padding: 12px 16px; }
  .chart-card { display: flex; flex-direction: column; gap: 8px; min-width: 0; }
  .chart-card h1 { margin: 0; font-size: 18px; line-height: 1.3; }
  .chart-head { display: flex; justify-content: space-between; align-items: flex-start; gap: 12px; }
  .icon-button {
    flex: none; width: 32px; height: 32px; border: 1px solid var(--border-strong); border-radius: 7px;
    background: var(--surface); color: var(--ink-2); display: inline-flex; align-items: center; justify-content: center; cursor: pointer;
  }
  .chart-actions { display: flex; gap: 6px; flex: none; }
  .icon-button:hover { background: var(--primary-tint); color: var(--primary); }
  .chart-card.fullscreen { border-radius: 0; overflow: auto; }
  .message { margin: 0; padding: 48px 0; text-align: center; color: var(--ink-3); }
  .partial-note { display: block; font-weight: 600; color: var(--ink); margin-bottom: 2px; }
  .partial-mark { font-size: 15px; font-weight: 700; margin-right: 4px; }
  .note { margin: 0; font-weight: 400; font-size: 12px; line-height: 1.35; color: var(--ink-2); }
  /* Fills the window below the header; text flows into a second column once there's room for two readable ones. */
  .about { min-height: calc(100vh - 88px); line-height: 1.4; display: flex; flex-direction: column; }
  .about h1 { margin: 0 0 8px; font-size: 24px; }
  .about-text { columns: 2 34em; column-gap: 48px; column-rule: 1px solid var(--border); flex: 1; }
  .about-text :global(:first-child) { margin-top: 0; }
  .about-text :global(.keep) { break-inside: avoid; }
  .about-text :global(.keep > ul.lead) { margin-bottom: 0.25em; }
  .about-text :global(li), .about-text :global(p) { break-inside: avoid; }
  .about-text :global(p) { margin: 0 0 0.6em; }
  .about-text :global(ul) { margin: 0 0 0.6em; padding-left: 1.2em; }
  .about-text :global(li) { margin-bottom: 0.25em; }
  .pulled { margin: 24px 0 0; padding-top: 14px; border-top: 1px solid var(--border); font-size: 14px; color: var(--ink-2); }
  .about :global(h3) { font-family: var(--font-display); font-weight: 400; font-size: 22px; }
  .about :global(h4) { font-family: var(--font-display); font-weight: 400; font-size: 18px; line-height: 1.25; margin: 16px 0 4px; }
  @media (max-width: 640px) { .page { padding: 16px 12px 32px; } .card { padding: 16px; } }
</style>
