import { defineConfig } from 'vite'
import { svelte } from '@sveltejs/vite-plugin-svelte'
import { resolve } from 'node:path'

export default defineConfig({
  // The app is served from a sub-path on GitHub Pages; relative asset URLs
  // keep the build portable. Data files are fetched from ./data/ at runtime.
  base: './',
  plugins: [svelte()],
  optimizeDeps: { exclude: ['@duckdb/duckdb-wasm'] },
  build: {
    target: 'es2022',
    rollupOptions: {
      input: {
        main: resolve(import.meta.dirname, 'index.html'),
        bench: resolve(import.meta.dirname, 'bench/index.html')
      }
    }
  },
  worker: { format: 'es' }
})
