import { defineConfig } from 'vite'
import { resolve } from 'node:path'

export default defineConfig({
  // The app is served from a sub-path on GitHub Pages; relative asset URLs
  // keep the build portable. Data files are fetched from /data/ at runtime.
  base: './',
  optimizeDeps: { exclude: ['@duckdb/duckdb-wasm'] },
  build: {
    target: 'es2022',
    rollupOptions: {
      input: { bench: resolve(import.meta.dirname, 'bench/index.html') }
    }
  },
  worker: { format: 'es' }
})
