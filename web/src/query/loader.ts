// Browser-side access to the exported data (web/public/data/, written by
// data-raw/10_export_web.R): the manifest, and decoded (theme, geo_level)
// partitions with a small least-recently-used cache. The UI asks for a
// partition with loadPartition(); prefetch() warms the next likely one (PT)
// when the browser is idle. See docs/wasm-port-plan.md, "Loading strategy".

import { decodeSeriesFacts, type SeriesFactsColumns } from './columns'

export interface PartitionEntry {
  theme: string
  geo_level: string
  path: string
  rows: number
  bytes: number
}

export interface Manifest {
  built_at: string
  data_through: string
  n_tables: number
  series_facts: PartitionEntry[]
  files: { path: string; bytes: number; hash: string }[]
}

/** About 4 decoded partitions stay in memory (2.9 MB of Parquet in total, so this is a margin for iOS Safari). */
const MAX_CACHED = 4

export class DataStore {
  private manifestPromise: Promise<Manifest> | null = null
  private cache = new Map<string, Promise<SeriesFactsColumns>>()

  /** `baseUrl` points at the exported data directory, e.g. `${import.meta.env.BASE_URL}data/`. */
  constructor(readonly baseUrl: string) {}

  manifest(): Promise<Manifest> {
    this.manifestPromise ??= fetch(new URL('manifest.json', this.url()), { cache: 'no-cache' })
      .then((r) => this.ok(r).json() as Promise<Manifest>)
    return this.manifestPromise
  }

  async json<T>(path: string): Promise<T> {
    const m = await this.manifest()
    const entry = m.files.find((f) => f.path === path)
    // The hash makes the URL change whenever the content does, so caches never go stale.
    const url = new URL(entry ? `${path}?v=${entry.hash}` : path, this.url())
    return this.ok(await fetch(url)).json() as Promise<T>
  }

  loadPartition(theme: string, geoLevel: string): Promise<SeriesFactsColumns> {
    const key = `${theme}/${geoLevel}`
    const hit = this.cache.get(key)
    if (hit) {
      this.cache.delete(key) // re-insert to mark as most recently used
      this.cache.set(key, hit)
      return hit
    }
    const pending = this.manifest().then(async (m) => {
      const entry = m.series_facts.find((p) => p.theme === theme && p.geo_level === geoLevel)
      if (!entry) throw new Error(`No data for ${theme} at ${geoLevel}`)
      const res = this.ok(await fetch(new URL(entry.path, this.url())))
      return decodeSeriesFacts(await res.arrayBuffer())
    })
    pending.catch(() => this.cache.delete(key)) // let a failed load be retried
    this.cache.set(key, pending)
    while (this.cache.size > MAX_CACHED) this.cache.delete(this.cache.keys().next().value!)
    return pending
  }

  /** Warm a partition without blocking, when the browser has nothing better to do. */
  prefetch(theme: string, geoLevel: string): void {
    const run = () => { this.loadPartition(theme, geoLevel).catch(() => {}) }
    if ('requestIdleCallback' in window) requestIdleCallback(run, { timeout: 5000 })
    else setTimeout(run, 1000)
  }

  private url(): string {
    return new URL(this.baseUrl, location.href).href
  }

  private ok(res: Response): Response {
    if (!res.ok) throw new Error(`${res.status} ${res.statusText} for ${res.url}`)
    return res
  }
}
