// Phase 0 timing comparison (docs/wasm-port-plan.md, "Phase 0 timing
// comparison"). One page load runs one contender through a short session -
// the default view cold, the same view warm, then a switch to PT, a second
// theme, and a CSD drill - and records where the time goes at each step.
//
//   A  DuckDB-WASM, theme x geo_level files loaded into in-memory tables
//   B  DuckDB-WASM, one file per theme queried over HTTP with read_parquet()
//   C  no database engine: hyparquet decode + TypeScript aggregation
//
// Usage: /bench/?c=A  (or B, C). Results land in window.__bench and a table.
// Every data URL gets a per-load cache-buster, so the first step is cold.

type Contender = 'A' | 'B' | 'C'
type Granularity = 'Annual' | 'Monthly'

interface View {
  id: string
  theme: string
  geoLevel: string
  series: string
  facet: string
  granularity: Granularity
  category: 'breakdown_1' | 'geo_1' | 'total'
  geoFilter: string[]
  residual: boolean
  years: [number, number]
}

interface Agg { category: string; year: number; month: number | null; value: number }

interface StepResult {
  step: string
  contender: Contender
  bootMs: number
  fetchMs: number
  decodeMs: number
  queryMs: number
  totalMs: number
  dataBytes: number
  rows: number
  checksum: string
}

const PR = 'permanent_residents'
const VIEWS: Record<string, View> = {
  v1: { id: 'v1', theme: PR, geoLevel: 'National', series: 'All admissions', facet: 'Immigration Category',
        granularity: 'Annual', category: 'breakdown_1', geoFilter: [], residual: true, years: [2015, 2026] },
  v4: { id: 'v4', theme: PR, geoLevel: 'PT', series: 'All admissions', facet: 'Total',
        granularity: 'Annual', category: 'geo_1', geoFilter: [], residual: false, years: [2015, 2026] },
  v2: { id: 'v2', theme: 'study_permit_holders', geoLevel: 'PT', series: 'All permits (Year became effective)',
        facet: 'Total', granularity: 'Monthly', category: 'geo_1', geoFilter: [], residual: false, years: [2000, 2026] },
  v3: { id: 'v3', theme: PR, geoLevel: 'CSD', series: 'All admissions', facet: 'Total',
        granularity: 'Annual', category: 'total', geoFilter: ['Ontario', 'Toronto', 'Toronto'], residual: false,
        years: [2015, 2026] }
}
// The session each contender runs, in order.
const SESSION: [string, string][] = [
  ['1 cold: PR National by category', 'v1'],
  ['1 warm: same view again', 'v1'],
  ['4: switch PR to Province/Territory', 'v4'],
  ['2: Study permits PT monthly (new theme)', 'v2'],
  ['3: PR one CSD (Toronto)', 'v3']
]

const params = new URLSearchParams(location.search)
// Allowlisted: the value is echoed into the results table's markup.
const rawContender = (params.get('c') ?? 'A').toUpperCase()
if (!['A', 'B', 'C'].includes(rawContender)) throw new Error(`unknown contender: use ?c=A, B or C`)
const contender = rawContender as Contender
const bust = `cb=${Date.now()}${Math.random().toString(36).slice(2, 8)}`

interface ManifestFile { theme: string; geo_level: string; path: string; rows: number; bytes: number }
let manifest: { series_facts: ManifestFile[] }

const dataUrl = (path: string) => new URL(`/data/${path}?${bust}`, location.href).href
const benchUrl = (theme: string) => new URL(`/bench/theme=${theme}.parquet?${bust}`, location.href).href

function partitionPath(theme: string, geoLevel: string): string {
  const f = manifest.series_facts.find((p) => p.theme === theme && p.geo_level === geoLevel)
  if (!f) throw new Error(`no partition for ${theme}/${geoLevel}`)
  return f.path
}

function bytesSince(mark: number, match: (name: string) => boolean): number {
  return (performance.getEntriesByType('resource') as PerformanceResourceTiming[])
    .filter((e) => e.startTime >= mark && match(e.name))
    .reduce((a, e) => a + (e.transferSize || e.encodedBodySize || 0), 0)
}

// ---- shared post-processing (same for every contender) -------------------
// Mirrors build_series_plot_data(): fold all but the top N categories into
// "Other", append the Suppressed Residual against the published total, then
// order periods. Kept identical across contenders so only the data path differs.
function finish(rows: Agg[], published: Map<number, number> | null, topN = 10) {
  const periodKey = (r: Agg) => (r.month == null ? `${r.year}` : `${r.year}-${String(r.month).padStart(2, '0')}`)
  const totals = new Map<string, number>()
  for (const r of rows) totals.set(r.category, (totals.get(r.category) ?? 0) + r.value)
  const keep = new Set([...totals.entries()].sort((a, b) => b[1] - a[1]).slice(0, topN).map(([c]) => c))
  const out = new Map<string, number>()
  for (const r of rows) {
    const cat = totals.size > topN && !keep.has(r.category) ? 'Other' : r.category
    const k = `${cat}␟${periodKey(r)}`
    out.set(k, (out.get(k) ?? 0) + r.value)
  }
  if (published) {
    const visible = new Map<number, number>()
    for (const r of rows) visible.set(r.year, (visible.get(r.year) ?? 0) + r.value)
    for (const [year, total] of published) {
      const gap = Math.max(0, total - (visible.get(year) ?? 0))
      if (gap > 0) out.set(`Suppressed Residual␟${year}`, gap)
    }
  }
  const sorted = [...out.entries()].sort((a, b) => (a[0] < b[0] ? -1 : 1))
  const sum = sorted.reduce((a, [, v]) => a + v, 0)
  return { rows: sorted.length, checksum: `${sorted.length}/${Math.round(sum)}` }
}

// ---- contenders A and B: DuckDB-WASM ------------------------------------
import * as duckdb from '@duckdb/duckdb-wasm'
import ehWasm from '@duckdb/duckdb-wasm/dist/duckdb-eh.wasm?url'
import ehWorker from '@duckdb/duckdb-wasm/dist/duckdb-browser-eh.worker.js?url'

let db: duckdb.AsyncDuckDB
let conn: duckdb.AsyncDuckDBConnection
const loadedTables = new Set<string>()

// ?engine=cold also cache-busts the worker and .wasm, so the browser can't
// reuse its HTTP cache or compiled-code cache - a first-ever visit.
const coldEngine = params.get('engine') === 'cold'
const engineUrl = (u: string) => (coldEngine ? `${new URL(u, location.href).href}?${bust}` : new URL(u, location.href).href)

async function bootDuckDB() {
  const worker = new Worker(engineUrl(ehWorker), { type: 'classic' })
  db = new duckdb.AsyncDuckDB(new duckdb.VoidLogger(), worker)
  await db.instantiate(engineUrl(ehWasm))
  conn = await db.connect()
}

function viewSql(table: string, v: View): { sql: string; args: unknown[] } {
  const cat = v.category === 'total' ? `'Total'` : v.category
  const month = v.granularity === 'Monthly' ? 'period_month' : 'NULL::INTEGER'
  const where = ['series = ?', 'facet = ?', 'period_year BETWEEN ? AND ?']
  const args: unknown[] = [v.series, v.facet, v.years[0], v.years[1]]
  v.geoFilter.forEach((g, i) => { where.push(`geo_${i + 1} = ?`); args.push(g) })
  if (table.startsWith('read_parquet')) { where.push('geo_level = ?'); args.push(v.geoLevel) }
  return {
    sql: `SELECT ${cat} AS category, period_year AS year, ${month} AS month, sum(value) AS value
          FROM ${table} WHERE ${where.join(' AND ')} GROUP BY ALL`,
    args
  }
}

function publishedSql(table: string, v: View): { sql: string; args: unknown[] } {
  const where = ['series = ?', `facet = 'Total'`, 'period_year BETWEEN ? AND ?']
  const args: unknown[] = [v.series, v.years[0], v.years[1]]
  if (table.startsWith('read_parquet')) { where.push('geo_level = ?'); args.push(v.geoLevel) }
  return { sql: `SELECT period_year AS year, sum(value) AS value FROM ${table} WHERE ${where.join(' AND ')} GROUP BY ALL`, args }
}

async function runSql(q: { sql: string; args: unknown[] }) {
  const stmt = await conn.prepare(q.sql)
  try {
    return (await stmt.query(...q.args)).toArray().map((r) => r.toJSON())
  } finally {
    await stmt.close()
  }
}

function toAgg(rows: Record<string, unknown>[]): Agg[] {
  return rows.map((r) => ({
    category: r.category == null ? 'NA' : String(r.category),
    year: Number(r.year),
    month: r.month == null ? null : Number(r.month),
    value: Number(r.value)
  }))
}

async function stepDuckDB(v: View, layout: 'A' | 'B') {
  let fetchMs = 0, decodeMs = 0
  const mark = performance.now()
  let table: string
  if (layout === 'A') {
    table = `t_${v.theme}_${v.geoLevel}`
    if (!loadedTables.has(table)) {
      const t0 = performance.now()
      const buf = new Uint8Array(await (await fetch(dataUrl(partitionPath(v.theme, v.geoLevel)))).arrayBuffer())
      fetchMs = performance.now() - t0
      const t1 = performance.now()
      await db.registerFileBuffer(`${table}.parquet`, buf)
      await conn.query(`CREATE TABLE ${table} AS SELECT * FROM read_parquet('${table}.parquet')`)
      decodeMs = performance.now() - t1
      loadedTables.add(table)
    }
  } else {
    const name = `b_${v.theme}.parquet`
    if (!loadedTables.has(name)) {
      await db.registerFileURL(name, benchUrl(v.theme), duckdb.DuckDBDataProtocol.HTTP, false)
      loadedTables.add(name)
    }
    table = `read_parquet('${name}')`
  }
  const t2 = performance.now()
  const rows = toAgg(await runSql(viewSql(table, v)))
  let published: Map<number, number> | null = null
  if (v.residual) {
    published = new Map(toAgg(await runSql(publishedSql(table, v))).map((r) => [r.year, r.value]))
  }
  const result = finish(rows, published)
  const queryMs = performance.now() - t2
  const dataBytes = bytesSince(mark, (n) => n.includes('.parquet'))
  return { fetchMs, decodeMs, queryMs, dataBytes, ...result }
}

// ---- contender C: hyparquet + TypeScript ---------------------------------
type Columns = Record<string, ArrayLike<unknown>>
const COLUMNS = ['series', 'facet', 'geo_1', 'geo_2', 'geo_3', 'breakdown_1', 'period_year', 'period_month', 'value']
const decoded = new Map<string, Columns>()
let hyparquet: typeof import('hyparquet')
let compressors: typeof import('hyparquet-compressors')['compressors']

async function bootHyparquet() {
  const [hp, hc] = await Promise.all([import('hyparquet'), import('hyparquet-compressors')])
  hyparquet = hp
  compressors = hc.compressors
}

async function decodeColumns(buf: ArrayBuffer): Promise<Columns> {
  const parts: Record<string, { start: number; data: ArrayLike<unknown> }[]> = {}
  await hyparquet.parquetRead({
    file: buf,
    columns: COLUMNS,
    compressors,
    onChunk: ({ columnName, columnData, rowStart }) => {
      (parts[columnName] ??= []).push({ start: rowStart, data: columnData })
    }
  })
  const out: Columns = {}
  for (const name of COLUMNS) {
    const chunks = (parts[name] ?? []).sort((a, b) => a.start - b.start)
    out[name] = chunks.length === 1 ? chunks[0].data : chunks.flatMap((c) => Array.from(c.data))
  }
  return out
}

function aggregateColumns(cols: Columns, v: View, facet: string, byCategory: boolean): Agg[] {
  const series = cols.series, fac = cols.facet, year = cols.period_year, month = cols.period_month, value = cols.value
  const catCol = v.category === 'total' ? null : cols[v.category]
  const geoCols = v.geoFilter.map((_, i) => cols[`geo_${i + 1}`])
  const monthly = v.granularity === 'Monthly'
  const sums = new Map<string, Agg>()
  for (let i = 0; i < series.length; i++) {
    if (series[i] !== v.series || fac[i] !== facet) continue
    const y = Number(year[i])
    if (y < v.years[0] || y > v.years[1]) continue
    let ok = true
    for (let g = 0; g < geoCols.length; g++) if (geoCols[g][i] !== v.geoFilter[g]) { ok = false; break }
    if (!ok) continue
    const val = value[i] == null ? 0 : Number(value[i])
    const m = monthly && month[i] != null ? Number(month[i]) : null
    const cat = !byCategory ? '' : catCol ? (catCol[i] == null ? 'NA' : String(catCol[i])) : 'Total'
    const key = `${cat}␟${y}␟${m}`
    const cur = sums.get(key)
    if (cur) cur.value += val
    else sums.set(key, { category: cat, year: y, month: m, value: val })
  }
  return [...sums.values()]
}

async function stepHyparquet(v: View) {
  let fetchMs = 0, decodeMs = 0
  const mark = performance.now()
  const key = `${v.theme}/${v.geoLevel}`
  let cols = decoded.get(key)
  if (!cols) {
    const t0 = performance.now()
    const buf = await (await fetch(dataUrl(partitionPath(v.theme, v.geoLevel)))).arrayBuffer()
    fetchMs = performance.now() - t0
    const t1 = performance.now()
    cols = await decodeColumns(buf)
    decodeMs = performance.now() - t1
    decoded.set(key, cols)
  }
  const t2 = performance.now()
  const rows = aggregateColumns(cols, v, v.facet, true)
  const published = v.residual
    ? new Map(aggregateColumns(cols, { ...v, granularity: 'Annual' }, 'Total', false).map((r) => [r.year, r.value]))
    : null
  const result = finish(rows, published)
  const queryMs = performance.now() - t2
  return { fetchMs, decodeMs, queryMs, dataBytes: bytesSince(mark, (n) => n.includes('.parquet')), ...result }
}

// ---- runner --------------------------------------------------------------
async function run() {
  manifest = await (await fetch(`/data/manifest.json?${bust}`)).json()
  const results: StepResult[] = []
  const bootStart = performance.now()
  if (contender === 'C') await bootHyparquet()
  else await bootDuckDB()
  const bootMs = performance.now() - bootStart
  const engineBytes = bytesSince(bootStart - 1, (n) => !n.includes('.parquet') && !n.includes('manifest'))

  for (const [i, [label, viewId]] of SESSION.entries()) {
    const v = VIEWS[viewId]
    const t0 = performance.now()
    const r = contender === 'C' ? await stepHyparquet(v) : await stepDuckDB(v, contender)
    const stepMs = performance.now() - t0
    const boot = i === 0 ? bootMs : 0
    results.push({ step: label, contender, bootMs: boot, fetchMs: r.fetchMs, decodeMs: r.decodeMs, queryMs: r.queryMs,
                   totalMs: boot + stepMs, dataBytes: r.dataBytes, rows: r.rows, checksum: r.checksum })
  }
  const summary = { contender, engineBytes, userAgent: navigator.userAgent, results }
  ;(window as unknown as { __bench: unknown }).__bench = summary
  render(summary)
}

function render(s: { contender: Contender; engineBytes: number; results: StepResult[] }) {
  const f = (n: number) => n.toFixed(0)
  const rows = s.results.map((r) =>
    `<tr><td>${r.step}</td><td>${f(r.bootMs)}</td><td>${f(r.fetchMs)}</td><td>${f(r.decodeMs)}</td>` +
    `<td>${f(r.queryMs)}</td><td><strong>${f(r.totalMs)}</strong></td><td>${(r.dataBytes / 1024).toFixed(0)}</td>` +
    `<td>${r.checksum}</td></tr>`).join('')
  document.getElementById('out')!.innerHTML =
    `<h2>Contender ${s.contender}</h2><p>Engine/module bytes transferred: ${(s.engineBytes / 1024).toFixed(0)} KB</p>` +
    `<table><thead><tr><th>Step</th><th>Boot</th><th>Fetch</th><th>Decode/build</th><th>Query</th>` +
    `<th>Total (ms)</th><th>Data KB</th><th>Check</th></tr></thead><tbody>${rows}</tbody></table>`
}

run().catch((e) => {
  document.getElementById('out')!.textContent = `Error: ${e?.stack ?? e}`
  ;(window as unknown as { __bench: unknown }).__bench = { error: String(e) }
})
