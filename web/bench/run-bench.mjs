// Runs the Phase 0 bench (bench/index.html) in headless Chrome and prints
// median timings per contender. Serves the production build (dist/) itself so
// it can mimic a static host:
//   - gzip for .js/.wasm/.json/.html (GitHub Pages and Cloudflare Pages both
//     compress these; .parquet is already zstd-compressed, so it isn't),
//   - HTTP Range + HEAD support (contender B reads Parquet over HTTP ranges),
//   - optional server-side bandwidth/latency throttling, shared across all
//     responses, so engine and data downloads (including the ones the DuckDB
//     worker makes, which page-level DevTools throttling may not cover) are
//     slowed the same way.
//
// Usage (from web/, after `npx vite build`):
//   node bench/run-bench.mjs [--runs 5] [--mbps 9 --latency 60]
// Needs puppeteer-core (PUPPETEER_PATH=/path/to/puppeteer-core works too) and
// a local Chrome (CHROME_PATH overrides the macOS default).

import http from 'node:http'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import zlib from 'node:zlib'

const args = Object.fromEntries(process.argv.slice(2).join(' ').split('--').filter(Boolean)
  .map((s) => s.trim().split(/\s+/)).map(([k, v]) => [k, v ?? 'true']))
const RUNS = Number(args.runs ?? 5)
const MBPS = args.mbps ? Number(args.mbps) : null
const LATENCY_MS = Number(args.latency ?? 0)
const CONTENDERS = (args.contenders ?? 'A,B,C').split(',')
const CHROME = process.env.CHROME_PATH ?? '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'
const DIST = path.resolve(import.meta.dirname, '..', 'dist')

const { default: puppeteer } = await import(process.env.PUPPETEER_PATH ?? 'puppeteer-core')

// ---- static server --------------------------------------------------------
const TYPES = { '.html': 'text/html', '.js': 'text/javascript', '.mjs': 'text/javascript', '.wasm': 'application/wasm',
                '.json': 'application/json', '.parquet': 'application/octet-stream', '.css': 'text/css' }
const COMPRESS = new Set(['.html', '.js', '.mjs', '.wasm', '.json', '.css'])
const gzCache = new Map()

// One shared token bucket: concurrent responses split the bandwidth, like a
// real connection.
let nextFree = 0
async function throttledWrite(res, buf) {
  if (!MBPS) return void res.end(buf)
  const bytesPerMs = (MBPS * 1e6) / 8 / 1000
  for (let off = 0; off < buf.length; off += 16384) {
    const chunk = buf.subarray(off, off + 16384)
    const now = performance.now()
    nextFree = Math.max(nextFree, now) + chunk.length / bytesPerMs
    const wait = nextFree - now
    if (wait > 1) await new Promise((r) => setTimeout(r, wait))
    if (!res.write(chunk)) await new Promise((r) => res.once('drain', r))
  }
  res.end()
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://x')
  let file = path.join(DIST, decodeURIComponent(url.pathname))
  if (!file.startsWith(DIST)) return void res.writeHead(403).end()
  if (fs.existsSync(file) && fs.statSync(file).isDirectory()) file = path.join(file, 'index.html')
  if (!fs.existsSync(file)) return void res.writeHead(404).end()
  if (LATENCY_MS) await new Promise((r) => setTimeout(r, LATENCY_MS))

  const ext = path.extname(file)
  const headers = { 'Content-Type': TYPES[ext] ?? 'application/octet-stream', 'Accept-Ranges': 'bytes',
                    'Cache-Control': 'max-age=3600', 'Access-Control-Allow-Origin': '*' }
  const range = req.headers.range?.match(/bytes=(\d+)-(\d*)/)
  const size = fs.statSync(file).size
  if (range) {
    const start = Number(range[1])
    const end = range[2] ? Number(range[2]) : size - 1
    res.writeHead(206, { ...headers, 'Content-Range': `bytes ${start}-${end}/${size}`, 'Content-Length': end - start + 1 })
    if (req.method === 'HEAD') return void res.end()
    const fd = fs.openSync(file, 'r')
    const buf = Buffer.alloc(end - start + 1)
    fs.readSync(fd, buf, 0, buf.length, start)
    fs.closeSync(fd)
    return throttledWrite(res, buf)
  }
  let body = fs.readFileSync(file)
  if (COMPRESS.has(ext) && /gzip/.test(req.headers['accept-encoding'] ?? '')) {
    if (!gzCache.has(file)) gzCache.set(file, zlib.gzipSync(body, { level: 6 }))
    body = gzCache.get(file)
    headers['Content-Encoding'] = 'gzip'
  }
  res.writeHead(200, { ...headers, 'Content-Length': req.method === 'HEAD' && !headers['Content-Encoding'] ? size : body.length })
  if (req.method === 'HEAD') return void res.end()
  return throttledWrite(res, body)
})
await new Promise((r) => server.listen(0, '127.0.0.1', r))
const BASE = `http://127.0.0.1:${server.address().port}`

// ---- runs -------------------------------------------------------------------
// Each run gets its own Chrome with a brand-new profile: an empty disk cache
// (a first-ever visit) that can still hold the 34 MB engine for a repeat load.
// Puppeteer's incognito contexts use a small in-memory cache that can't.
async function runOnce(contender, engine) {
  const profile = fs.mkdtempSync(path.join(os.tmpdir(), 'migrascope-bench-'))
  const browser = await puppeteer.launch({ executablePath: CHROME, headless: true, userDataDir: profile,
                                           args: ['--no-first-run', '--no-default-browser-check'] })
  const page = await browser.newPage()
  // "first": one load with the engine cache-busted. "repeat": two loads with
  // the engine at its normal URL - the first primes the HTTP and compiled-code
  // caches, the second is measured. Data files are cache-busted on every load.
  const loads = engine === 'repeat' ? ['warm', 'warm'] : ['cold']
  let last
  for (const mode of loads) {
    await page.goto(`${BASE}/bench/?c=${contender}&engine=${mode}`)
    await page.waitForFunction('window.__bench', { timeout: 600000, polling: 200 })
    last = await page.evaluate('window.__bench')
    if (last.error) throw new Error(`${contender}: ${last.error}`)
  }
  await browser.close()
  fs.rmSync(profile, { recursive: true, force: true })
  return last
}

const median = (xs) => { const s = [...xs].sort((a, b) => a - b); return s[Math.floor(s.length / 2)] }
const out = { condition: MBPS ? `${MBPS} Mbps, ${LATENCY_MS} ms latency` : 'unthrottled', runs: RUNS, contenders: {} }
for (const engine of ['first', 'repeat']) {
  for (const c of CONTENDERS) {
    const runs = []
    for (let i = 0; i < RUNS; i++) runs.push(await runOnce(c, engine))
    const steps = runs[0].results.map((s, j) => ({
      step: s.step,
      checksum: s.checksum,
      ...Object.fromEntries(['bootMs', 'fetchMs', 'decodeMs', 'queryMs', 'totalMs', 'dataBytes']
        .map((k) => [k, Math.round(median(runs.map((r) => r.results[j][k])))]))
    }))
    out.contenders[`${c}-${engine}`] = steps
    console.error(`${c} ${engine}: ${steps.map((s) => s.totalMs).join(' / ')} ms`)
  }
}
server.close()
console.log(JSON.stringify(out, null, 1))
