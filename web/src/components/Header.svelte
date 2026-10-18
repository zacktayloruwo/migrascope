<script lang="ts">
  import type { Explorer } from '../lib/state.svelte'
  import type { I18n } from '../lib/i18n'

  let { app, i18n }: { app: Explorer; i18n: I18n } = $props()
</script>

<header>
  <div class="inner">
    <div class="brand">
      <!-- Microscope (Lucide, ISC licence) -->
      <svg width="28" height="28" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"
           stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
        <path d="M6 18h8" /><path d="M3 22h18" /><path d="M14 22a7 7 0 1 0 0-14h-1" /><path d="M9 14h2" />
        <path d="M9 12a2 2 0 0 1-2-2V6h6v4a2 2 0 0 1-2 2Z" /><path d="M12 6V3a1 1 0 0 0-1-1H9a1 1 0 0 0-1 1v3" />
      </svg>
      <span class="logotype">MigraScope</span>
      <span class="suffix">{i18n.t('app_title_suffix', app.lang)}</span>
    </div>
    <nav aria-label="Main">
      <button type="button" aria-current={app.view === 'plot' ? 'page' : undefined}
              class:active={app.view === 'plot'} onclick={() => (app.view = 'plot')}>
        {i18n.t('nav_visualize', app.lang)}
      </button>
      <button type="button" aria-current={app.view === 'about' ? 'page' : undefined}
              class:active={app.view === 'about'} onclick={() => (app.view = 'about')}>
        {i18n.t('nav_about', app.lang)}
      </button>
      <button type="button" class="lang" lang={app.lang === 'en' ? 'fr' : 'en'}
              onclick={() => (app.lang = app.lang === 'en' ? 'fr' : 'en')}>
        {i18n.t('lang_toggle_to_fr', app.lang)}
      </button>
    </nav>
  </div>
</header>

<style>
  header { background: var(--bar); color: #fff; }
  .inner {
    max-width: 1280px; margin: 0 auto; padding: 12px 24px;
    display: flex; flex-wrap: wrap; align-items: center; justify-content: space-between; gap: 12px;
  }
  .brand { display: flex; align-items: center; gap: 10px; min-width: 0; }
  .logotype { font-family: var(--font-display); font-size: 26px; line-height: 1; }
  .suffix { font-size: 15px; font-weight: 600; opacity: 0.95; }
  nav { display: flex; flex-wrap: wrap; gap: 6px; }
  nav button {
    border: 1px solid rgba(255, 255, 255, 0.6); background: transparent; color: #fff;
    border-radius: 8px; padding: 9px 14px; font-weight: 600; cursor: pointer; min-height: 44px;
  }
  nav button:hover { background: rgba(255, 255, 255, 0.15); }
  nav button.active { background: #fff; color: var(--primary); border-color: #fff; }
  @media (max-width: 640px) { .suffix { display: none; } }
</style>
