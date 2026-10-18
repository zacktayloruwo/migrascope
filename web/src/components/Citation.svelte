<script lang="ts">
  // Source citation for the source tables behind the current view - app.R's
  // table_citation_ui(). Synthetic tables with no CKAN resource of their own
  // (the merged refugees table) cite their sibling tables instead.
  import type { I18n, Lang } from '../lib/i18n'
  import type { SourceRecord } from '../lib/meta'

  let { viewIds, seriesIds, sources, lang, i18n }: {
    viewIds: string[]; seriesIds: string[]; sources: SourceRecord[]; lang: Lang; i18n: I18n
  } = $props()

  /** app_utils.R: extract_table_hash() - the 8-hex resource prefix in a table_id. */
  const hashOf = (id: string) => /\/([0-9a-f]{8})__/.exec(id)?.[1] ?? null

  const rows = $derived.by(() => {
    let hashes = viewIds.map(hashOf)
    if (hashes.every((h) => h === null)) hashes = seriesIds.map(hashOf)
    const wanted = new Set(hashes.filter((h): h is string => h !== null))
    return sources.filter((s) => wanted.has(s.hash))
  })
  const agency = $derived([...new Set(rows.map((r) => r.agency))].join(' / '))
  const datasetUrls = $derived([...new Set(rows.map((r) => r.dataset_url))])
  const today = new Date().toISOString().slice(0, 10)
</script>

{#if rows.length}
  <p class="citation">
    {i18n.t('citation_source', lang)}{agency}{i18n.t('citation_portal', lang)}
    {#each rows as r, i (r.hash)}
      <a href={r.url} target="_blank" rel="noopener">“{r.table_name}” ({r.format})</a>{i18n.t('citation_last_updated', lang, r.updated_at)}{i < rows.length - 1 ? '; ' : ''}
    {/each}
    ({#each datasetUrls as url, i (url)}<a href={url} target="_blank" rel="noopener">{i18n.t('citation_dataset_page', lang)}{datasetUrls.length > 1 ? ` ${i + 1}` : ''}</a>{i < datasetUrls.length - 1 ? ', ' : ''}{/each}).
    {i18n.t('citation_last_accessed', lang, today)}
  </p>
{/if}

<style>
  .citation { margin: 0; font-size: 11px; line-height: 1.3; color: #5A6578; }
</style>
