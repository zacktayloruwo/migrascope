<script lang="ts">
  // The explorer's inputs, laid out as a sentence ("Show <theme> <series>
  // broken down by <facet> in <place>") with the remaining options below.
  // Every control is a native <select>/<button>, so keyboard and screen-reader
  // support come for free; the state rules live in Explorer, not here.
  import { GEO_LEVELS, GRANULARITIES, type Explorer, type GeoLevel } from '../lib/state.svelte'
  import { THEMES, type I18n } from '../lib/i18n'
  import type { Granularity } from '../query/plotData'

  let { app, i18n }: { app: Explorer; i18n: I18n } = $props()

  const l = $derived(app.lang)
  const geoLabelKey: Record<GeoLevel, string> = {
    national: 'national', PT: 'province_territory', CMA: 'cma', CD: 'cd', CSD: 'csd'
  }
  const granKey: Record<Granularity, string> = { Monthly: 'monthly', Quarterly: 'quarterly', Annual: 'annual' }
  const yearOptions = $derived(app.scope
    ? Array.from({ length: app.scope.max_year - app.scope.min_year + 1 }, (_, i) => app.scope!.min_year + i)
    : [])
  const themes = $derived(THEMES.filter((t) => app.meta.summary.some((r) => r.theme === t.id)))
  const unavailable = $derived(GEO_LEVELS.filter((g) => !app.geoAvailable.has(g)))
  const TOP_N_CHOICES = Array.from({ length: 14 }, (_, i) => i + 2) // 2-15, as in the R app
  /** "Max categories shown (rest grouped as 'Other')" split before the bracket, shown on two lines. */
  const topNLabel = $derived.by(() => {
    const text = i18n.t('top_n_label', l)
    const i = text.indexOf(' (')
    return i < 0 ? [text, ''] : [text.slice(0, i), text.slice(i + 1)]
  })
</script>

<section class="card" aria-label={l === 'fr' ? 'Paramètres du graphique' : 'Chart settings'}>
  <p class="sentence">
    <span class="word">{l === 'fr' ? 'Afficher' : 'Show'}</span>
    <select class="pill" aria-label={i18n.t('theme_label', l)} value={app.theme}
            onchange={(e) => app.setTheme(e.currentTarget.value)}>
      {#each themes as t (t.id)}<option value={t.id}>{t[l]}</option>{/each}
    </select>
    <select class="pill" aria-label={i18n.t('series_label', l)} value={app.series}
            onchange={(e) => app.setSeries(e.currentTarget.value)}>
      {#each app.seriesOptions as s (s)}<option value={s}>{i18n.translate(s || '(unnamed series)', 'series', l)}</option>{/each}
    </select>

    {#if app.showBreakdown}
      <span class="word">{l === 'fr' ? 'réparti par' : 'broken down by'}</span>
      <select class="pill" aria-label={i18n.t('breakdown_label', l)} value={app.catLevel}
              onchange={(e) => app.setCatLevel(e.currentTarget.value)}>
        {#each app.catChoices as c (c)}
          <option value={c}>{c === 'none' ? i18n.t('none_choice', l) : i18n.translate(c, 'facet', l)}</option>
        {/each}
      </select>
      {#if app.drill1Needed}
        <span class="word" aria-hidden="true">›</span>
        <select class="pill" aria-label={i18n.t('drill1_label', l)} value={app.drill1}
                onchange={(e) => app.setDrill1(e.currentTarget.value)}>
          <option value="none">{i18n.t('drill_all_choice', l)}</option>
          {#each app.drill1Values as v (v)}<option value={v}>{i18n.category(v, l)}</option>{/each}
        </select>
        {#if app.drill2Needed}
          <span class="word" aria-hidden="true">›</span>
          <select class="pill" aria-label={i18n.t('drill2_label', l)} value={app.drill2}
                  onchange={(e) => app.setDrill2(e.currentTarget.value)}>
            <option value="none">{i18n.t('drill_all_of', l, i18n.category(app.drill1, l))}</option>
            {#each app.drill2Values as v (v)}<option value={v}>{i18n.category(v, l)}</option>{/each}
          </select>
        {/if}
      {/if}
    {/if}

    {#if app.showGeoUnit}
      <span class="word">{l === 'fr' ? 'dans' : 'in'}</span>
      <select class="pill" aria-label={i18n.t('geo_unit_label', l)} value={app.geoUnit}
              onchange={(e) => app.setGeoUnit(e.currentTarget.value)}>
        {#each app.geoUnitChoices.values as v, i (v)}
          <option value={v}>{v === 'All' ? i18n.t('all_choice', l) : app.geoUnitChoices.labels[i]}</option>
        {/each}
      </select>
    {/if}
  </p>

  <div class="options">
    <div class="group" role="group" aria-labelledby="lbl-geo">
      <span class="label" id="lbl-geo">{i18n.t('geo_agg_label', l)}</span>
      <div class="segmented">
        {#each GEO_LEVELS as g (g)}
          <button type="button" aria-pressed={app.geoLevel === g} disabled={!app.geoAvailable.has(g)}
                  title={!app.geoAvailable.has(g) ? i18n.t('geo_not_available', l) : undefined}
                  onclick={() => app.setGeoLevel(g)}>{i18n.t(geoLabelKey[g], l)}</button>
        {/each}
      </div>
      {#if unavailable.length}
        <span class="hint">{unavailable.map((g) => i18n.t(geoLabelKey[g], l)).join(', ')}: {i18n.t('geo_not_available', l).toLowerCase()}</span>
      {/if}
    </div>

    <div class="group" role="group" aria-labelledby="lbl-gran">
      <span class="label" id="lbl-gran">{i18n.t('granularity_label', l)}</span>
      <div class="segmented">
        <!-- All three shown; those finer than the series is published at are greyed out, like geography. -->
        {#each GRANULARITIES as g (g)}
          <button type="button" aria-pressed={app.granularity === g} disabled={!app.granularityChoices.includes(g)}
                  title={!app.granularityChoices.includes(g) ? i18n.t('geo_not_available', l) : undefined}
                  onclick={() => (app.granularity = g)}>
            {i18n.t(granKey[g], l)}
          </button>
        {/each}
      </div>
    </div>

    <div class="group" role="group" aria-labelledby="lbl-display">
      <span class="label" id="lbl-display">{i18n.t('display_as_label', l)}</span>
      <div class="segmented">
        <button type="button" aria-pressed={app.displayAs === 'absolute'} onclick={() => (app.displayAs = 'absolute')}>
          {i18n.t('absolute_values', l)}
        </button>
        <button type="button" aria-pressed={app.displayAs === 'percent'} disabled={!app.percentAllowed}
                onclick={() => (app.displayAs = 'percent')}>{i18n.t('percentage_total', l)}</button>
      </div>
    </div>

    <div class="group">
      <span class="label" id="lbl-years">{i18n.t('year_range_label', l)}</span>
      <div class="years">
        <select aria-label={l === 'fr' ? 'Première année' : 'First year'} value={app.years[0]}
                onchange={(e) => app.setYears(Number(e.currentTarget.value), app.years[1])}>
          {#each yearOptions as y (y)}<option value={y}>{y}</option>{/each}
        </select>
        <span class="arrow" aria-hidden="true">→</span>
        <select aria-label={l === 'fr' ? 'Dernière année' : 'Last year'} value={app.years[1]}
                onchange={(e) => app.setYears(app.years[0], Number(e.currentTarget.value))}>
          {#each yearOptions as y (y)}<option value={y}>{y}</option>{/each}
        </select>
      </div>
    </div>

    <label class="group inline">
      <span class="label">{topNLabel[0]}{#if topNLabel[1]}<br />{topNLabel[1]}{/if}</span>
      <select value={app.topN} onchange={(e) => (app.topN = Number(e.currentTarget.value))}>
        {#each TOP_N_CHOICES as n (n)}<option value={n}>{n}</option>{/each}
      </select>
    </label>
  </div>
</section>

<style>
  .card {
    background: var(--surface); border: 1px solid var(--border); border-radius: var(--radius);
    padding: 12px 16px; display: flex; flex-direction: column; gap: 10px;
  }
  .sentence {
    margin: 0; display: flex; flex-wrap: wrap; align-items: center; gap: 6px 8px;
    font-size: 16px; line-height: 1.4;
  }
  .word { color: var(--ink-2); }
  .pill {
    appearance: none; border: 0; border-radius: 7px; max-width: 100%;
    background: var(--primary-tint) url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='16' height='16' viewBox='0 0 24 24' fill='none' stroke='%232348C4' stroke-width='2.5' stroke-linecap='round' stroke-linejoin='round'%3E%3Cpath d='m6 9 6 6 6-6'/%3E%3C/svg%3E") no-repeat right 8px center / 14px;
    color: var(--primary); font-weight: 600; font-size: 15px;
    padding: 3px 28px 3px 10px; cursor: pointer; text-overflow: ellipsis;
  }
  .pill:hover { background-color: #dde5ff; }
  .options {
    display: flex; flex-wrap: wrap; gap: 8px 18px; align-items: flex-start;
    border-top: 1px solid var(--border); padding-top: 10px; font-size: 13px;
  }
  .group { display: flex; flex-direction: column; gap: 3px; }
  .label { color: var(--ink-3); font-weight: 600; font-size: 12px; max-width: 220px; line-height: 1.3; }
  .hint { color: var(--ink-3); font-weight: 400; font-size: 11px; max-width: 360px; }
  .segmented { display: flex; flex-wrap: wrap; border: 1px solid var(--border-strong); border-radius: 7px; overflow: hidden; }
  .segmented button {
    border: 0; border-left: 1px solid var(--border-strong); background: var(--surface);
    padding: 4px 9px; cursor: pointer; min-height: 30px;
  }
  .segmented button:first-child { border-left: 0; }
  .segmented button[aria-pressed='true'] { background: var(--primary); color: #fff; font-weight: 600; }
  .segmented button:disabled { color: #8A93A2; background: #F4F2EE; cursor: not-allowed; }
  .years { display: flex; align-items: center; gap: 6px; }
  .group.inline { flex-direction: row; align-items: center; gap: 8px; }
  .arrow { color: var(--ink-3); }
  .years select, .group select {
    border: 1px solid var(--border-strong); border-radius: 7px; padding: 3px 6px; background: var(--surface); min-height: 30px;
  }
  @media (max-width: 640px) {
    .card { padding: 12px; }
    /* Larger touch targets on phones. */
    .segmented button, .years select, .group select { min-height: 40px; }
  }
</style>
