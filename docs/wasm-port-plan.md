# MigraScope: port plan (Shiny → static JS + DuckDB‑WASM + Parquet)

*Drafted 2026‑10‑18 against branch `feature/bilingual-fr` (commit `60a65b4`).*

## 1. Why, and what changes

Today MigraScope is a Shiny app (`app/app.R`, ~1,000 lines, plus `app/R/app_utils.R`, ~1,350) that holds a 310 MB `immigration.duckdb` on a shinyapps.io / Posit Connect server and re‑queries it on each input change. Porting it to a **static site** where **DuckDB‑WASM queries Parquet files in the browser** gets you:

- **No server.** It runs on GitHub Pages, Cloudflare Pages or Netlify for free. Nothing sleeps, there are no instance‑hour limits, and many users can visit at once.
- **Faster interaction.** Queries run locally, so there's no websocket round trip and no 400 ms debounce working around server latency.
- **Shareable state.** Every view is a URL. Shiny can't easily do this today.
- **A clean split between data and app.** The R pipeline stays the single source of truth and the web app only ever reads its exported files.

**Non‑goals:** porting the data‑prep pipeline (`data-raw/00`–`09`) out of R. It stays as it is and gains one export step.

### The key finding: the data is tiny once in Parquet

I measured this against the current database:

| Object | Rows | Size |
|---|---|---|
| `immigration.duckdb` (everything, incl. raw `facts`) | — | 310 MB |
| `series_facts` (the only table the app reads) | 4,525,616 | — |
| → one Parquet file, zstd | | **2.8 MB** |
| → partitioned by theme, sorted, zstd | | 16 KB (refugees) to 880 KB (study permits), **2.8 MB total** |
| → partitioned by theme × geo_level, sorted, zstd | | 8 KB to 528 KB per file, 21 files, **2.8 MB total** |

Per‑file sizes with the theme × geo_level split (zstd, sorted):

| Theme | National | PT | CMA | CD | CSD |
|---|---|---|---|---|---|
| Permanent residents | 140 KB | 392 KB | 40 KB | 44 KB | 180 KB |
| Study permit holders | 312 KB | 528 KB | 20 KB | — | — |
| IMP | 128 KB | 376 KB | 32 KB | 36 KB | 100 KB |
| TFWP | 72 KB | 228 KB | — | — | — |
| Asylum claimants | 40 KB | 112 KB | — | — | — |
| TR → PR transition | 16 KB | 56 KB | — | — | — |
| Refugees | 12 KB | 8 KB | — | — | — |

So the data download isn't really a problem. The **DuckDB‑WASM engine** (about 3–4 MB compressed for the `eh` bundle) is the largest thing the browser fetches. The design below works around that:
- Selectors are drawn from small JSON before DuckDB has finished loading.
- Each **(theme, geo_level)** Parquet file is loaded into an in‑memory table the first time it's needed. Files are at most 528 KB, so there's no need for HTTP range reads.

### Why split by geographic level as well as theme

After the engine boots, the slowest step is decoding Parquet and building the in‑memory table, not downloading it. Natively, loading the whole permanent residents theme (1.28 M rows) takes **0.39 s**. A query on the loaded table then takes **6 ms**. WASM is typically 2–4× slower than native, so loading a whole theme could add roughly 1–1.5 s before the first chart on each theme change, more on phones. (These are native measurements; Phase 0 measures the WASM numbers.)

Splitting by geo_level fits how the app queries:
- **Every view uses exactly one geographic level.** `geo_level` is always an equality filter, and both the breakdown rows and the published total behind the Suppressed residual come from the same level. No query ever spans two files.
- **Most sessions start at National,** which is the smallest file in every theme except refugees (5–6× smaller than the whole theme for permanent residents and IMP). The first chart decodes far fewer rows.
- **The heaviest levels (PT, CSD) load only when someone asks for them.** Most users never open CD or CSD.
- **The landing cards** need only National files, and the Province/Territory map needs only PT.

**Loading strategy:**
1. On theme select, load `theme=<t>/geo_level=National` and draw the chart.
2. When the browser is idle, prefetch the same theme's PT file, which is the next most likely level.
3. Fetch CMA, CD and CSD only when the user picks them, behind a short skeleton.
4. Keep at most about 4 files as in‑memory tables, dropping the least recently used (total data is 2.8 MB, so this is a safety margin for iOS Safari, not a necessity).

**Alternative considered:** keep one file per theme, sorted by `geo_level` first with small row groups, and query `read_parquet()` directly so DuckDB skips row groups using their min/max statistics. That avoids 21 files, but it decodes on every query instead of once, and its row‑group skipping in WASM is less predictable. Phase 0 compares both approaches and the result decides.

---

## 2. Target architecture

```
R pipeline (unchanged 00–09)
   └─ NEW data-raw/10_export_web.R ──► web/public/data/
                                         ├─ series_facts/theme=<slug>/geo_level=<lvl>.parquet  (sorted, zstd; 21 files)
                                         ├─ series_summary.json                  (drives every selector)
                                         ├─ geo_units.json                       (PT/CMA/CD/CSD pickers)
                                         ├─ translations.parquet                 (category_translations + series/facet FR)
                                         ├─ sources.json                         (manifest → citation lookup)
                                         ├─ descriptions.json                    (ⓘ popup content, en+fr, see §5)
                                         ├─ events.json                          (optional chart annotations, see §4)
                                         └─ manifest.json                        (build date, version hash, n_tables, file checksums)

web/  (Vite + TypeScript)
   ├─ src/db/        duckdb-wasm boot, theme loader, SQL query builders
   ├─ src/state/     URL-synced app state (single store)
   ├─ src/i18n/      strings.en.json / strings.fr.json (from R/i18n.R STRINGS)
   ├─ src/components/ Selectors, Chart, InfoTip, Citation, DataTable, About
   └─ tests/         parity tests against R golden outputs
```

### Stack recommendation

- **Build:** Vite + TypeScript.
- **UI framework:** **Svelte 5**. The selector cascade (theme → series → geography → breakdown → drill‑1 → drill‑2) is a reactive dependency graph, which `$derived` expresses directly. Bundles are small, and it's the closest mental model to Shiny reactives. (React works too, at the cost of more boilerplate around effect ordering, which is the very kind of bug `app.R` has a lot of comments about.)
- **Charts:** **Apache ECharts**. It has animated transitions between views, a legend you can click to hide categories or hover to highlight them, `dataZoom` for long monthly series, a built‑in SVG/PNG export, an ARIA "decal" pattern fill (useful for Suppressed Residual), and a choropleth map, all in one library. Observable Plot is the more elegant static alternative but would need hand‑built interactivity.
- **Popovers:** the native HTML **Popover API** with **Floating UI** for positioning (CSS anchor positioning isn't yet consistent across browsers).
- **DuckDB:** `@duckdb/duckdb-wasm`, pinned to a version, bundles self‑hosted (avoids a CDN dependency and CSP issues), single‑threaded `eh` bundle (no COOP/COEP headers needed, so any static host works).

### Data export (`data-raw/10_export_web.R`)

1. `COPY (SELECT … FROM series_facts ORDER BY theme, geo_level, series, facet, geo_1, geo_2, geo_3, breakdown_1, breakdown_2, breakdown_3, period_year, period_month) TO 'web/public/data/series_facts' (FORMAT parquet, COMPRESSION zstd, PARTITION_BY (theme, geo_level), ROW_GROUP_SIZE 100000)`. Sorting is what got 4.5 M rows down to 2.8 MB. The partition columns aren't stored inside the files, so the loader adds `theme` and `geo_level` back as constants when it builds each table. The export also writes a small file index (theme, geo_level, path, rows, bytes, hash) into `manifest.json`.
2. Precompute `build_series_summary()` (currently run at Shiny startup) and write it as JSON so the UI can render before DuckDB exists.
3. Precompute the distinct geo units per (theme, series, facet, geo_level), i.e. `list_series_geo_units()`, as JSON with the display labels (", ON" suffixes, west‑to‑east province order) already resolved. These lists are small and needed immediately.
4. Export `category_translations` and `SERIES_FACET_LABELS_FR` together as one translations table. Unlike `translate_vec()`, which runs a SQL query per call, the browser loads it once into a `Map`.
5. Write `sources.json` from `build_source_lookup(manifest)`, keyed by the 8‑char hash.
6. Write per‑series facts for the popups: year range, last‑updated date, contributing source tables, share of cells suppressed, stock vs flow, and the latest complete period (see §4, partial years).
7. Write `manifest.json` with content hashes. Filenames get a hash suffix (`theme=permanent_residents/geo_level=National.3f9a1c.parquet`) so browsers and CDNs can cache them forever, and a data refresh is just a new manifest.
8. Remove `immigration.duckdb` from what gets deployed. It stays a pipeline artifact.

### Porting the query layer (R → SQL in TS)

Push as much as possible into DuckDB SQL rather than re‑implementing dplyr in JS:

| R function (`app/R/app_utils.R`) | Port |
|---|---|
| `build_series_summary()` | precomputed JSON (pipeline) |
| `list_series_geo_units()` | precomputed JSON (pipeline) |
| `list_series_breakdown_values()` | SQL `SELECT DISTINCT` on the loaded theme table |
| `fetch_series_rows()` + `aggregate_series()` | one SQL query per view (sketch below) |
| stock "latest month per leaf entity" | `QUALIFY row_number() OVER (PARTITION BY entity, year[, quarter] ORDER BY period_month DESC) = 1` |
| `fetch_series_published_total()` + Suppressed Residual | CTE in the same query: `GREATEST(0, published - visible)` |
| `collapse_to_top_n()` | window `rank() OVER (ORDER BY cat_total DESC)`, then `CASE WHEN rk <= n THEN category ELSE 'Other' END` |
| `order_categories()`, `is_ordinal_cohort()`, `category_colors()` | small pure TS functions (unit‑tested) |
| `to_percent_of_total()` | SQL window `value / sum(value) OVER (PARTITION BY period)` |
| `translate_vec()` | in‑memory `Map` lookup, with the same scoped‑then‑unscoped‑then‑English fallback |
| `series_source_table_ids()`, `table_citation_ui()` | SQL distinct + `sources.json` |
| `parse_geo_unit()`, `PROVINCE_ABBR`, `PROVINCE_ORDER_WEST_TO_EAST` | TS constants |

Query sketch (annual, stock series):

```sql
WITH base AS (
  SELECT concat_ws('␟', geo_1, geo_2, geo_3, breakdown_1, breakdown_2, breakdown_3) AS entity,
         breakdown_1 AS category, period_year, period_quarter, period_month, value
  FROM sf WHERE series = ? AND facet = ? AND geo_level = ? AND period_year BETWEEN ? AND ?
),
latest AS (
  SELECT * FROM base
  QUALIFY row_number() OVER (PARTITION BY entity, period_year ORDER BY period_month DESC) = 1
),
agg AS (SELECT category, period_year AS period, sum(value) AS value FROM latest GROUP BY ALL),
ranked AS (
  SELECT *, dense_rank() OVER (ORDER BY sum(value) OVER (PARTITION BY category) DESC) AS rk FROM agg
)
SELECT CASE WHEN rk <= ? THEN category ELSE 'Other' END AS category, period, sum(value) AS value
FROM ranked GROUP BY ALL ORDER BY period;
```

All values go in as prepared‑statement parameters, never as interpolated strings.

### Proving parity (the most important engineering step)

The R logic has a lot of hard‑won edge cases: stock tables, NA quarters in pre‑2015 years, the residual being skipped when a drill is active, ordinal age cohorts, CD/CSD name collisions. To avoid re‑discovering them:

1. Write `data-raw/11_export_golden.R`. It picks around 300 view configurations, stratified across every theme × geo_level × granularity × facet, plus every drill combination and both display modes. For each it runs the **existing** `build_series_plot_data()` and writes inputs and outputs to `web/tests/golden/*.json`.
2. In `vitest`, run the TS query layer against the same Parquet using `@duckdb/node-api` (same SQL engine) and assert equal rows, category order, and values to 1e‑9.
3. Run this in CI on every push. A pipeline refresh regenerates the golden files.

---

## 3. Feature parity checklist

- [ ] Theme / Series / Geographic unit / Break down by / Drill 1 / Drill 2 cascade, with the same defaults (series ranked by scope count, geo depth, …)
- [ ] Granularity limited to what the series supports; year range resets to the series span
- [ ] Geographic aggregation ranks disabled when unavailable, **with the reason shown inline** rather than only in a `title` tooltip
- [ ] Absolute vs % of total (disabled for a single bar)
- [ ] Top‑N folding into "Other"; Suppressed Residual at the top level only
- [ ] Stock‑table title suffix and aggregation rule
- [ ] Stacking order: largest at bottom, ordinal cohorts kept in order, Other / NA / Suppressed in fixed colours
- [ ] EN/FR toggle for all chrome, theme/series/facet labels, category values and number formats (space thousands separator, decimal comma)
- [ ] Citation footer from the contributing source tables, with the merged‑refugees fallback
- [ ] About page (`ABOUT.md` / `ABOUT_fr.md` rendered at build time, `{{N_TABLES}}` filled from `manifest.json`)
- [ ] Full‑screen chart

---

## 4. Making the interface more engaging and understandable

Ordered roughly by value for effort.

### 4.1 Plain‑language "sentence builder" controls
The sidebar currently exposes internal vocabulary (Series, Facet, Geographic aggregation, Drill into…). Restate the selection as an editable sentence above the chart, with each underlined phrase a dropdown:

> Show **permanent residents admitted** · broken down by **immigration category** · in **Ontario** · **per year** · **2015–2025**

The full sidebar stays as an "Advanced" panel. The sentence doubles as the chart title, which removes the current `→`‑joined title.

### 4.2 Click to drill, breadcrumbs to climb
- Clicking a bar segment for a province sets the geographic unit. Clicking a breakdown category sets Drill 1 / Drill 2 when deeper nesting exists. The cursor and tooltip say "Click to see Ontario by …".
- A breadcrumb trail (`Canada › Ontario › Economic › Skilled workers`) where any crumb steps back up.
- Browser Back/Forward work because state lives in the URL.

### 4.3 Shareable, citable views
- The URL hash encodes the full state (`#t=permanent_residents&s=All+admissions&f=Immigration+Category&g=PT:Ontario&gran=A&y=2015-2025&lang=fr`).
- A **Share** button copies the link. **Cite** copies a formatted citation (APA / Chicago) of the view, including the source tables and access date.
- **Download** CSV of exactly what's plotted, plus PNG/SVG of the chart. Academics and journalists will use this most.

### 4.4 Landing overview instead of a blank default
The first screen shows one card per theme: headline figure for the latest complete year, year‑over‑year change, a 10‑year sparkline, and a one‑line description. Clicking a card opens that theme. This teaches the scope of the data before anyone touches a control.

### 4.5 Auto‑generated takeaway line
Under the chart, a sentence computed from the plotted data: *"In 2025, 395,000 permanent residents were admitted, 18% fewer than 2024. Economic class made up 58%."* (illustrative numbers). It's templated in both languages, so no LLM is needed. It makes the chart readable at a glance and helps screen‑reader users.

### 4.6 Be honest about partial years and data quirks
- **Year to date:** IRCC tables are cumulative monthly updates, so the current year in Annual view looks like a collapse. Mark the latest year as **"YTD to Aug 2026"** with lighter bars and a note, and default the takeaway sentence to the last *complete* year.
- **Suppressed Residual:** draw it with a hatched pattern (ECharts `decal`) rather than just a colour, with an ⓘ explanation.
- **Stock vs flow:** a small badge ("Snapshot on Dec 31" vs "Admissions during period") next to the title.
- **Known caveats** surface automatically when relevant, e.g. the asylum "Claim Month" vs "Claim Year" ~3× discrepancy, the refugee series splice at 2021/2022, and NOC 2011 vs 2021 occupation codes.

### 4.7 More ways to look at the same numbers
A chart‑type toggle that picks a sensible default per view:
- **Stacked bars** (current default)
- **Lines.** Better for comparing trends across categories; the default when there are more than 6 categories over more than 20 periods.
- **100% stacked**, replacing the separate "% of total" radio
- **Small multiples.** One mini chart per category on a shared y‑axis, for comparing provinces.
- **Map.** A choropleth for the Province/Territory level, using a simplified StatCan boundary GeoJSON (~100 KB) with a time slider. CMA as proportional circles later.

### 4.8 Legend and tooltip upgrades
- Hovering a legend entry highlights that series; clicking it toggles the series; double‑click isolates it.
- The tooltip shows the value, share of the bar, and change from the previous period. For **Other** it lists the top few folded‑in categories ("Other (37): Mexico 1,200, Brazil 980, …").
- A `dataZoom` brush under monthly charts.

### 4.9 Optional context annotations
Toggleable vertical markers for policy and world events (COVID border closures, the 2024 study‑permit cap, the start of Express Entry in 2015, annual Levels Plans). They're stored in `events.json`, authored in the repo with a citation per event, and shown in both languages. This needs your curation for accuracy, so it's off by default until it's populated.

### 4.10 Polish that adds up
- A loading skeleton instead of a blank chart while DuckDB boots (selectors are already usable from JSON). Then prefetch the other themes' Parquet when the browser is idle.
- Animated transitions between views so changes are easy to follow.
- Colours: the current 7‑stop gradient isn't colour‑blind safe and becomes indistinguishable beyond about 8 categories. Replace it with the prototype palette in §4.11.
- Responsive layout: on phones the controls become a bottom sheet and the chart is full width.
- Dark mode via CSS tokens.
- Accessibility (WCAG 2.1 AA): keyboard operable throughout, ARIA labels, a "View as table" toggle, and the takeaway sentence as the chart's accessible description.

### 4.11 Visual theme: "youngnoto" (chosen in the design prototype)

The [design prototype](https://claude.ai/artifact/SgF86RrXJz9e2qMg2NtG3s) settled the look. Build it as CSS custom properties in `web/src/styles/tokens.css`.

**Type**
- **Young Serif** (one weight, 400) for the "MigraScope" logotype and headings h1–h2. Its heavy letterforms read as bold without a bold weight.
- **Noto Sans** (400–700) for everything else: controls, body text, tables, tooltips and numbers, with `font-variant-numeric: tabular-nums` in tables and the readout panel. Its French accents and spacing are already proven in the current app.
- Load both through Google Fonts with `display=swap`, or self‑host the woff2 files alongside the Parquet for an offline‑capable build.

**Brand chrome**
- Top bar: coral `#E8506A` with white text, and a microscope line icon (24–28 px) to the left of the logotype.
- Primary and links: royal blue `#2348C4`; hover `#172F8A`.
- Page ground: warm off‑white `#FAF7F2`. Cards: white with a `#E7E1D6` border and 18 px corners.
- Focus ring: 3 px coral.

**Chart categories** (checked under simulated protanopia, deuteranopia and tritanopia; the four colours differ by at least 42 in every simulation):

| Role | Colour |
|---|---|
| 1st category (largest, bottom of stack) | `#2348C4` royal blue |
| 2nd | `#5BC0EB` sky |
| 3rd | `#E8506A` coral |
| 4th | `#FFB627` amber |
| Suppressed residual | grey hatch (`#9AA3AE` / `#E3E7EC`) |
| Other / NA | fixed greys |

More than 4 categories need an extended palette checked the same way before use.

**Contrast items to fix before launch**
- White 15 px nav text on the coral bar is 3.6:1, below the 4.5:1 AA minimum. Either deepen the bar to about `#D13F5A` (4.6:1) or make the nav text 19 px bold.
- In Lines view the amber and sky strokes fall below 3:1 against white. Darken those strokes or add point markers.

---

## 5. Data‑description (ⓘ) popups

### Component
`<InfoTip id="theme.permanent_residents" />` renders a small circled‑i button (`aria-label="About Permanent Residents"`, `aria-expanded`, `aria-controls`). Activating it opens a native `popover` positioned by Floating UI. Behaviour:
- Opens on click, tap, or Enter/Space. On desktop it also previews on hover after 300 ms.
- Esc or clicking outside closes it, and focus returns to the button.
- Width is capped at about 360 px. Content is short Markdown (bold, lists, links), sanitised at build time.
- The footer has links such as "Source dataset ↗", "Data notes in About ›" and "Download definitions".
- In French it reads `descriptions.json[id].fr` and falls back to English with a small "(EN)" tag.

### Where the icons go

| Location | Popup content |
|---|---|
| **Theme** selector + landing cards | What the population is, who's counted, and the unit of measure (persons, permits, claims, decisions), flow vs stock, publishing agency, update frequency, coverage years |
| **Series** selector | How this series differs from its siblings (e.g. "at December 31" snapshot vs "year became effective"; francophone admissions outside Québec) |
| **Break down by / drill** selectors | Definition of the dimension: NOC 2011 vs 2021, immigration category hierarchy, study level, country of citizenship vs birth vs persecution |
| **Geographic aggregation** | What PT, CMA, CD and CSD mean (with StatCan definition links), and why some levels are unavailable for a series |
| **Temporal aggregation** | How Quarterly/Annual are built: summed for flows, latest month per entity for stocks |
| **Max categories / Other** | The top‑N rule, and what "Other" contains for the current view (computed live) |
| **Suppressed Residual** legend item | IRCC/IRB suppression of 0–5 values, how the residual is computed, and the share suppressed in this view (computed live) |
| **Chart title badge** (stock/flow, YTD) | Meaning of the badge for this view |
| **Citation footer** | Excel vs CSV preference, least‑suppressed‑sibling rule, last‑updated vs last‑accessed |

### Content model and authoring
- **Hand‑written prose** lives in `content/descriptions.yml`, one entry per id (`theme.*`, `series.<theme>.<series>`, `facet.<name>`, `geo.<level>`, `control.*`, `category.other`, `category.suppressed`), with `en:` and `fr:` Markdown fields. YAML diffs cleanly in git and handles multi‑paragraph text better than Excel cells.
- **Computed facts** come from `10_export_web.R` and are merged in using `{{placeholders}}`: `{{min_year}}–{{max_year}}`, `{{last_updated}}`, `{{n_source_tables}}`, `{{pct_suppressed}}`, `{{latest_complete_period}}`. Popups can't go stale after a data refresh, which avoids repeating the hand‑typed "85 tables" problem the About page already had.
- **Starting content** can be drafted from what the repo already says: the CKAN package descriptions (fetched in `01_build_manifest.R`), the README caveats, `ABOUT.md`, and the data quality report. Then you review it.
- **Coverage check:** `10_export_web.R` warns (and CI fails) on any theme, series, facet or geo level that's in the data without an `en` description, and lists missing `fr` text, the same way the translation conflict CSVs work today.

---

## 6. Phased delivery

| Phase | Scope | Exit criterion |
|---|---|---|
| **0. Spike** (2–3 days) | Vite page boots DuckDB‑WASM from a static host, runs the stock and residual queries, draws one ECharts bar, and runs the timing comparison below | Comparison table filled in; layout decision recorded |
| **1. Data export + golden tests** | `10_export_web.R`, `11_export_golden.R`, TS query layer, vitest parity suite | 100% of golden cases pass |
| **2. Parity app** | Full selector cascade, chart, citation, About, EN/FR, URL state | Parity checklist (§3) complete; side‑by‑side spot check against Shiny |
| **3. ⓘ popups** | `InfoTip` component, `descriptions.yml` drafted for all themes/controls, coverage check | No missing `en` ids; FR drafted |
| **4. Engagement features** | Sentence builder, click‑to‑drill and breadcrumbs, share/cite/download, YTD marking, takeaway line, palette | Usability pass with 2–3 colleagues or students |
| **5. Extras** | Landing cards, line/small‑multiples/map views, annotations, dark mode | — |
| **6. Launch** | Accessibility audit, Lighthouse, deploy to Pages, run alongside Shiny for a month, then retire Shiny | Shiny URL redirects |

Phases 3 and 4 can run in parallel once phase 2 is done.

### Phase 0 timing comparison

Two layouts, measured the same way, so the decision rests on numbers from the browser rather than the native estimates above:

- **A. Theme × geo_level files (proposed):** load `geo_level=National` into an in‑memory table, query it, then load PT on demand.
- **B. One file per theme:** sorted by `geo_level` first with ~20k‑row row groups, queried with `read_parquet()` directly and no in‑memory table.

**Test views:**
1. Permanent residents, National, Immigration Category, Annual (the default view).
2. Study permit holders, PT, Total, Monthly (the largest single file).
3. Permanent residents, CSD, one Ontario CSD (a deep drill).
4. Switching from view 1 to Province/Territory on the same theme (the second query).

**Conditions:**
- Chrome desktop, unthrottled.
- Chrome with "Fast 4G" throttling and 4× CPU slowdown.
- A real iPhone in Safari.

Each run uses a cold cache, then a warm cache (served from the HTTP cache and the in‑memory table).

**Metrics,** captured with `performance.mark()`:
- engine boot (worker ready)
- bytes fetched
- Parquet fetch time
- decode/table‑build time
- query time
- time to first chart
- peak JS heap (Chrome) where available

| Metric (median of 5) | A, view 1 | B, view 1 | A, view 2 | B, view 2 | A, view 3 | B, view 3 | A, view 4 | B, view 4 |
|---|---|---|---|---|---|---|---|---|
| Bytes fetched | | | | | | | | |
| Fetch (ms) | | | | | | | | |
| Decode / build (ms) | | | | | | | | |
| Query (ms) | | | | | | | | |
| Time to first chart (ms) | | | | | | | | |

**Decision rule:** keep A unless B is within 100 ms of A on time to first chart for views 1 and 4 under throttling. If it is, prefer B for its simpler file layout. Either way, the query layer goes through a `loadView(theme, geoLevel)` function, so switching layouts later changes one module.

## 7. Risks and mitigations

- **First‑load weight (DuckDB‑WASM ~3–4 MB):** selectors and landing cards render from JSON straight away, the engine loads in a worker, and long‑lived cache headers plus hashed filenames make repeat visits instant. If it's still a problem, a fallback is to precompute the default view per theme as JSON.
- **Silent logic drift from the R version:** the golden‑file parity suite in CI, regenerated with each data refresh.
- **Safari/iOS memory:** keep about 4 (theme, geo_level) tables in memory and drop the least recently used. Total data is 2.8 MB, so the risk is low.
- **Lag when switching geographic level:** the first switch to PT, CMA, CD or CSD fetches a new file. PT is prefetched when the browser is idle; the smaller levels are under 200 KB and show a skeleton while loading.
- **Ongoing content work (descriptions, events):** computed placeholders keep the facts current, and the coverage check flags gaps automatically.
- **Two codebases during the overlap:** the R pipeline is shared. Only the Shiny UI is retired, and only after phase 6.

## 8. Decisions for you

1. **Framework:** Svelte (recommended) or React.
2. **Hosting:** GitHub Pages (simplest if the repo moves to GitHub) or Cloudflare Pages (better caching and headers).
3. **Description authoring:** YAML in the repo (recommended) or an Excel sheet like `label_overrides.xlsx`.
4. **Event annotations:** include them (needs your curation) or leave them out.
5. **Old Shiny deployments** (shinyapps.io and Posit Connect Cloud): redirect them or keep them running.
