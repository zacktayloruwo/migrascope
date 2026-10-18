import { defineConfig } from 'vite'
import { svelte } from '@sveltejs/vite-plugin-svelte'
import { resolve } from 'node:path'

// The Phase 0 engine bench (bench/) pulls in DuckDB-WASM's 34 MB engine, so
// it's only built on request: BENCH=1 npm run build.
const withBench = process.env.BENCH === '1'

export default defineConfig({
  // The app is served from a sub-path on GitHub Pages (/migrascope/);
  // relative asset URLs keep the build portable. Data files are fetched from
  // ./data/ at runtime.
  base: './',
  plugins: [svelte()],
  optimizeDeps: { exclude: ['@duckdb/duckdb-wasm'] },
  build: {
    target: 'es2022',
    rollupOptions: {
      input: {
        main: resolve(import.meta.dirname, 'index.html'),
        ...(withBench ? { bench: resolve(import.meta.dirname, 'bench/index.html') } : {})
      }
    }
  },
  worker: { format: 'es' }
})
