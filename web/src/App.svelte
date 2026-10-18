<script lang="ts">
  import { DataStore } from './query/loader'
  import { loadMeta, type DefaultView, type Meta } from './lib/meta'
  import { Explorer } from './lib/state.svelte'
  import { I18n, formatDate, formatMonth, themeLabel } from './lib/i18n'
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
        <div class="about-text">{@html app.meta.aboutHtml[app.lang]}</div>
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
        {#if partitionError}
          <p class="message" role="alert">{partitionError}</p>
        {:else if !app.plotData}
          <p class="message" aria-live="polite">{app.lang === 'fr' ? 'Chargement des données…' : 'Loading data…'}</p>
        {:else if app.plotData.rows.length === 0}
          <p class="message">{i18n.t('no_data', app.lang)}</p>
        {:else}
          <Chart data={app.plotData} lang={app.lang} {i18n} granularity={app.params?.granularity ?? 'Annual'}
                 percent={app.params?.displayAs === 'percent'} />
        {/if}
        <p class="note">{i18n.t('suppression_note', app.lang)}</p>
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
  .icon-button:hover { background: var(--primary-tint); color: var(--primary); }
  .chart-card.fullscreen { border-radius: 0; overflow: auto; }
  .message { margin: 0; padding: 48px 0; text-align: center; color: var(--ink-3); }
  .note { margin: 0; font-size: 12px; line-height: 1.35; color: var(--ink-2); }
  /* Fills the window below the header; text flows into a second column once there's room for two readable ones. */
  .about { min-height: calc(100vh - 88px); line-height: 1.6; display: flex; flex-direction: column; }
  .about h1 { margin: 0 0 8px; font-size: 24px; }
  .about-text { columns: 2 34em; column-gap: 48px; column-rule: 1px solid var(--border); flex: 1; }
  .about-text :global(:first-child) { margin-top: 0; }
  .about-text :global(h4) { break-after: avoid; }
  .about-text :global(li), .about-text :global(p) { break-inside: avoid; }
  .pulled { margin: 24px 0 0; padding-top: 14px; border-top: 1px solid var(--border); font-size: 14px; color: var(--ink-2); }
  .about :global(h3) { font-family: var(--font-display); font-weight: 400; font-size: 22px; }
  .about :global(h4) { font-size: 16px; margin: 18px 0 4px; }
  @media (max-width: 640px) { .page { padding: 16px 12px 32px; } .card { padding: 16px; } }
</style>
