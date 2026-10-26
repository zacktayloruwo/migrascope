// Small metadata files written by data-raw/10_export_web.R, loaded once at
// startup so every selector can render before any Parquet is decoded.

import { parquetRead } from 'hyparquet'
import { compressors } from 'hyparquet-compressors'
import type { DataStore } from '../query/loader'

/** One (theme, series, facet, geo_level) combination - R: build_series_summary(). */
export interface SummaryRow {
  theme: string
  series: string
  facet: string
  geo_level: string
  geo_depth: number
  has_breakdown_2: boolean
  has_breakdown_3: boolean
  has_month: boolean
  /** Monthly rows only at quarter ends (quarterly source): no Monthly view. */
  quarterly_only?: boolean
  is_stock: boolean
  min_year: number
  max_year: number
}

/** Geographic unit picker choices - R: list_series_geo_units(); "All" first. */
export interface GeoUnitsEntry {
  theme: string
  series: string
  facet: string
  geo_level: string
  values: string[]
  labels: string[]
}

export interface SourceRecord {
  hash: string
  agency: string
  table_name: string
  format: string
  url: string
  dataset_url: string
  updated_at: string
  /** Citation wording: IRCC/IRB files on the Open Government Portal, or a Statistics Canada table. */
  portal?: 'open_canada' | 'statcan'
  /** French names, where the source publishes them (Statistics Canada). */
  agency_fr?: string
  table_name_fr?: string
  dataset_url_fr?: string
}

/** A source record with its French names swapped in, where it has them. */
export function localizeSource(s: SourceRecord, lang: 'en' | 'fr'): SourceRecord {
  if (lang === 'en') return s
  return { ...s, agency: s.agency_fr ?? s.agency, table_name: s.table_name_fr ?? s.table_name,
           dataset_url: s.dataset_url_fr ?? s.dataset_url }
}

export interface StringsFile {
  strings: Record<string, { en: string; fr: string }>
  series_facet_fr: Record<string, string>
}

export interface DefaultView {
  theme: string
  series: string
  facet: string
  geo_level: string
  granularity: string
  years: [number, number]
  top_n: number
  display_as: string
  category_order: string[]
  period_order: string[]
  rows: { category: string | null; period: string; period_sort: number; value: number }[]
}

/** category_translations, unscoped rows only (the app never asks for a table-scoped one). */
export type Translations = Map<string, Map<string, string>>

export interface Meta {
  summary: SummaryRow[]
  geoUnits: GeoUnitsEntry[]
  sources: SourceRecord[]
  strings: StringsFile
  translations: Translations
  aboutHtml: { en: string; fr: string }
  dataThrough: string
  dataPulled: string | null
}

async function loadTranslations(store: DataStore): Promise<Translations> {
  const m = await store.manifest()
  const entry = m.files.find((f) => f.path === 'translations.parquet')
  const out: Translations = new Map()
  if (!entry) return out
  const buf = await (await fetch(new URL(`translations.parquet?v=${entry.hash}`, new URL(store.baseUrl, location.href)))).arrayBuffer()
  await parquetRead({
    file: buf,
    columns: ['en_text', 'context', 'table_id', 'fr_text'],
    compressors,
    rowFormat: 'object',
    onComplete: (rows) => {
      for (const r of rows as unknown as { en_text: string; context: string; table_id: string | null; fr_text: string | null }[]) {
        if (r.table_id != null || !r.fr_text) continue
        let ctx = out.get(r.context)
        if (!ctx) { ctx = new Map(); out.set(r.context, ctx) }
        if (!ctx.has(r.en_text)) ctx.set(r.en_text, r.fr_text)
      }
    }
  })
  return out
}

export async function loadMeta(store: DataStore): Promise<Meta> {
  const text = async (path: string) => {
    const m = await store.manifest()
    const f = m.files.find((x) => x.path === path)
    return (await fetch(new URL(f ? `${path}?v=${f.hash}` : path, new URL(store.baseUrl, location.href)))).text()
  }
  const [summary, geoUnits, sources, strings, translations, aboutEn, aboutFr, manifest] = await Promise.all([
    store.json<SummaryRow[]>('series_summary.json'),
    store.json<GeoUnitsEntry[]>('geo_units.json'),
    store.json<SourceRecord[]>('sources.json'),
    store.json<StringsFile>('strings.json'),
    loadTranslations(store),
    text('about_en.html'),
    text('about_fr.html'),
    store.manifest()
  ])
  return { summary, geoUnits, sources, strings, translations, aboutHtml: { en: aboutEn, fr: aboutFr },
           dataThrough: manifest.data_through, dataPulled: manifest.data_pulled ?? null }
}
