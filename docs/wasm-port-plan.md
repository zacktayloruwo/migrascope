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

So the data download isn't really a problem. The **DuckDB‑WASM engine** is by far the largest thing the browser would fetch: Phase 0 measured the 1.32.0 `eh` bundle at 34.2 MB raw, **7.8 MB gzipped**, plus a 0.77 MB worker. An earlier draft of this plan estimated 3–4 MB; that was wrong. The design below works around that:
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
1. The landing page renders entirely from `landing.json`, with no query engine involved.
2. On theme select, draw the first chart straight from `views/<theme>.default.json`, which is instant. At the same time, load `theme=<t>/geo_level=National` (and the DuckDB engine, if it's kept) in the background. The first change to any control is then served by the live query layer.
3. When the browser is idle, prefetch the same theme's PT file, which is the next most likely level.
4. Fetch CMA, CD and CSD only when the user picks them, behind a short skeleton.
5. Keep at most about 4 files as in‑memory tables, dropping the least recently used (total data is 2.8 MB, so this is a safety margin for iOS Safari, not a necessity).

**Alternative considered:** keep one file per theme, sorted by `geo_level` first with small row groups, and query `read_parquet()` directly so DuckDB skips row groups using their min/max statistics. That avoids 21 files, but it decodes on every query instead of once, and its row‑group skipping in WASM is less predictable. Phase 0 compares both approaches and the result decides.

---

## 2. Target architecture

```
R pipeline (unchanged 00–09)
   └─ NEW data-raw/10_export_web.R ──► web/public/data/
                                         ├─ series_facts/theme=<slug>/geo_level=<lvl>.parquet  (sorted, zstd; 21 files)
                                         ├─ landing.json                         (pre-aggregated landing cards)
                                         ├─ views/<theme>.default.json           (pre-aggregated default chart per theme)
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
- **Query engine: hyparquet + TypeScript** (adopted 2026‑10‑18 after Phase 0; see "Phase 0 results").
  - Decoding: `hyparquet` with `hyparquet-compressors` for zstd, about 94 KB gzipped together, compared with 7.8 MB for DuckDB‑WASM.
  - Aggregation: plain TypeScript in `web/src/query/`.
  - DuckDB‑WASM stays only as a dev dependency of the Phase 0 bench (`web/bench/`), for re‑running the comparison.
  - The first chart per theme still comes from pre‑aggregated JSON.

### Data export (`data-raw/10_export_web.R`)

1. `COPY (SELECT … FROM series_facts ORDER BY theme, geo_level, series, facet, geo_1, geo_2, geo_3, breakdown_1, breakdown_2, breakdown_3, period_year, period_month) TO 'web/public/data/series_facts' (FORMAT parquet, COMPRESSION zstd, PARTITION_BY (theme, geo_level), ROW_GROUP_SIZE 100000)`. Sorting is what got 4.5 M rows down to 2.8 MB. The partition columns aren't stored inside the files, so the loader adds `theme` and `geo_level` back as constants when it builds each table. The export also writes a small file index (theme, geo_level, path, rows, bytes, hash) into `manifest.json`.
2. Precompute `build_series_summary()` (currently run at Shiny startup) and write it as JSON so the UI can render before DuckDB exists.
3. Precompute the distinct geo units per (theme, series, facet, geo_level), i.e. `list_series_geo_units()`, as JSON with the display labels (", ON" suffixes, west‑to‑east province order) already resolved. These lists are small and needed immediately.
4. Export `category_translations` and `SERIES_FACET_LABELS_FR` together as one translations table. Unlike `translate_vec()`, which runs a SQL query per call, the browser loads it once into a `Map`.
5. Write `sources.json` from `build_source_lookup(manifest)`, keyed by the 8‑char hash.
6. Write per‑series facts for the popups: year range, last‑updated date, contributing source tables, share of cells suppressed, stock vs flow, and the latest complete period (see §4, partial years).
7. **Pre‑aggregate the entry points** with the existing R functions, so they're correct by construction:
   - `landing.json`: one record per theme with the headline series, unit label, latest complete year, its total, the change from the previous year, the 2015–latest annual values for the sparkline, any caveat flag, and the data‑through month. Built with `build_series_plot_data()` on each theme's default series, National, Total, Annual.
   - `views/<theme>.default.json`: exactly what the explorer plots on first opening each theme (default series and facet, National, the default granularity and year range, top 10). It includes category order, the residual, the takeaway‑sentence inputs and the source table IDs, so the first chart, its sentence and its citation need no query.
   - Each file is a few KB and is listed with its hash in `manifest.json`. The default‑view JSON must match the live query exactly, so it is added to the golden tests: the query layer is run on the same parameters and asserted equal.
8. Write `manifest.json` with content hashes. Filenames get a hash suffix (`theme=permanent_residents/geo_level=National.3f9a1c.parquet`) so browsers and CDNs can cache them forever, and a data refresh is just a new manifest.
9. Remove `immigration.duckdb` from what gets deployed. It stays a pipeline artifact.

### Porting the query layer (R → TypeScript), done in Phase 1

With DuckDB dropped, the R functions are ported to plain TypeScript in `web/src/query/plotData.ts`. The functions loop over decoded column arrays, at most a few hundred thousand rows per partition. The table below records where each R function went. The SQL sketch after it is kept for reference only, in case DuckDB is ever brought back for ad‑hoc queries.

| R function (`app/R/app_utils.R`) | TypeScript port |
|---|---|
| `build_series_summary()`, `list_series_geo_units()` | precomputed JSON (`10_export_web.R`) |
| `fetch_series_rows()` | `fetchSeriesRows()` |
| `aggregate_series()`, incl. stock latest month per entity | `aggregateSeries()` |
| `fetch_series_published_total()` + Suppressed Residual | inside `buildPlotData()` |
| `collapse_to_top_n()` | `collapseToTopN()` |
| `order_categories()`, `is_ordinal_cohort()` | `orderCategories()`, `isOrdinalCohort()` |
| `to_percent_of_total()` | `toPercentOfTotal()` |
| `build_series_plot_data()` | `buildPlotData()` |
| `list_series_breakdown_values()` | `listBreakdownValues()` |
| `series_source_table_ids()` | `sourceTableIds()` |
| `parse_geo_unit()`, `PROVINCE_ABBR`, `PROVINCE_ORDER_WEST_TO_EAST`, `GEO_UNIT_SEP` | `web/src/query/constants.ts` |
| `translate_vec()`, `category_colors()`, `table_citation_ui()` | Phase 2 (UI) |

**Ordering detail the port has to match:** dplyr's `group_by()` and `arrange()` sort strings in the C locale, while base R's `sort()` uses ICU collation for `en_CA`. The port reproduces each where R uses it: a plain comparison and `Intl.Collator('en-CA')` respectively.

Original SQL plan, for reference:

| R function (`app/R/app_utils.R`) | Port |
|---|---|

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

1. `data-raw/11_export_golden.R` (done) runs the **existing** `build_series_plot_data()` over **605 view configurations** and writes inputs and outputs to `web/tests/golden/<theme>.json`. The configurations cover:
   - every (theme, series, facet, geo_level) in `series_summary`, at every granularity it supports;
   - non‑National levels both as "All" places and narrowed to one place;
   - the first drill value at every depth;
   - deterministic percentage, top‑3 and narrowed‑year variants.

   It also writes 46 drill‑choice cases from `list_series_breakdown_values()`.
2. `web/tests/parity.test.ts` (done, `npm test`) runs `buildPlotData()` against the exported Parquet and asserts category order, period order and every value to 1e‑9. It also checks that the 7 pre‑aggregated default views equal the live query.
   - **Result: 658 of 658 pass.** The suite takes about 10 s.
   - Planted bugs are caught: reversing the stock "latest month" rule fails 22 cases, an off‑by‑one in the residual fails 497, and dropping the stack‑order reversal fails 355.
3. Run this in CI on every push, once the golden files and the exported data are available to CI (see open decisions). A data refresh reruns `10_export_web.R` then `11_export_golden.R`.

---

## 3. Feature parity checklist

Status as of 2026‑10‑18 (Phase 2, Svelte app in `web/src/`; run with `npm run dev` in `web/`):

- [x] Theme / Series / Geographic unit / Break down by / Drill 1 / Drill 2 cascade, with the same defaults (series ranked by scope count, geo depth, …). The rules are in `web/src/lib/state.svelte.ts`.
- [x] Granularity limited to what the series supports; year range resets to the series span. It resets only when the resolved view changes, not when you pick another place (a deliberate improvement).
- [x] Geographic aggregation ranks disabled when unavailable, **with the reason shown inline**.
- [x] Absolute vs % of total (disabled for a single bar).
- [x] Top‑N folding into "Other"; Suppressed Residual at the top level only. Covered by the parity tests.
- [x] Stock‑table title suffix and aggregation rule.
- [x] Stacking order matches R: largest at the bottom, ordinal cohorts kept in order, Other / NA / Suppressed in fixed colours, Suppressed hatched.
- [x] EN/FR for all chrome, theme/series/facet labels, category values and number formats.
- [x] Citation footer from the contributing source tables, with the merged‑refugees fallback.
- [x] About page (rendered at export time by `10_export_web.R`, with the live table count).
- [x] URL state: every view is a shareable link, restored on load (drill values are checked once the data arrives).
- [x] Full‑screen chart (Fullscreen API button on the chart card).
- [x] Show `views/<theme>.default.json` while the first partition loads, when the inputs match the defaults exactly. The PT partition is prefetched after National.
- [ ] Side‑by‑side comparison with the Shiny app across themes. So far: spot checks, plus the 658 data parity tests.

Phase 2 changes from the Shiny app:
- **Controls:** a "sentence" of pill‑style selects (Show *theme* *series* broken down by *facet* › *drill* in *place*) with the other options below. This is the plain‑language layout from §4.1, built with native `<select>`s.
- **Legend:** an HTML legend that wraps on phones; clicking an entry hides that category.
- **Bundle:** the app is 203 KB gzipped (ECharts is most of it). It could be split so ECharts loads in parallel with the data.

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
| **0. Spike** ✅ (2–3 days) | Vite page boots DuckDB‑WASM from a static host, runs the stock and residual queries, draws one ECharts bar, and runs the timing comparison below | Comparison table filled in; layout decision recorded |
| **1. Data export + golden tests** ✅ | `10_export_web.R`, `11_export_golden.R`, TS query layer, vitest parity suite | 100% of golden cases pass (658/658, 2026‑10‑18) |
| **2. Parity app** (in progress, Svelte) | Full selector cascade, chart, citation, About, EN/FR, URL state | Parity checklist (§3) complete; side‑by‑side spot check against Shiny |
| **3. ⓘ popups** | `InfoTip` component, `descriptions.yml` drafted for all themes/controls, coverage check | No missing `en` ids; FR drafted |
| **4. Engagement features** | Sentence builder, click‑to‑drill and breadcrumbs, share/cite/download, YTD marking, takeaway line, palette | Usability pass with 2–3 colleagues or students |
| **5. Extras** | Landing cards, line/small‑multiples/map views, annotations, dark mode | — |
| **6. Launch** | Accessibility audit, Lighthouse, deploy to Pages, run alongside Shiny for a month, then retire Shiny | Shiny URL redirects |

Phases 3 and 4 can run in parallel once phase 2 is done.

### Phase 0 timing comparison

Three contenders, measured the same way, so the decision rests on numbers from the browser rather than the native estimates above. A and B compare file layouts for DuckDB‑WASM. C tests whether the WASM engine is needed at all.

- **A. DuckDB‑WASM, theme × geo_level files (proposed):** load `geo_level=National` into an in‑memory table, query it, then load PT on demand.
- **B. DuckDB‑WASM, one file per theme:** sorted by `geo_level` first with ~20k‑row row groups, queried with `read_parquet()` directly and no in‑memory table.
- **C. No database engine: hyparquet + TypeScript.** Read the same theme × geo_level files as A with [hyparquet](https://github.com/hyparam/hyparquet) (a dependency‑free Parquet reader of tens of KB, with zstd through its companion `hyparquet-compressors` package). Decode only the needed columns into typed arrays, then filter and aggregate in plain TypeScript: the stock and residual logic plus top‑N, about 150 lines. There's no worker boot and no table build.

C has no engine to boot, so its "engine boot" row measures loading the hyparquet module. Its decode row covers Parquet into typed arrays, and its query row covers the TypeScript aggregation.

To keep the comparison fair, the TypeScript aggregation in C has to pass the same golden‑file parity tests (§2) as the SQL in A and B before its timings count.

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

One table per condition (desktop, throttled, iPhone), each value the median of 5 runs:

| Metric | A·1 | B·1 | C·1 | A·2 | B·2 | C·2 | A·3 | B·3 | C·3 | A·4 | B·4 | C·4 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| JS + engine bytes | | | | | | | | | | | | |
| Engine / module boot (ms) | | | | | | | | | | | | |
| Data bytes fetched | | | | | | | | | | | | |
| Fetch (ms) | | | | | | | | | | | | |
| Decode / build (ms) | | | | | | | | | | | | |
| Query / aggregate (ms) | | | | | | | | | | | | |
| Time to first chart (ms) | | | | | | | | | | | | |

(Columns are contender·view, e.g. C·4 is contender C on view 4.)

**Decision rules,** applied to the throttled table:
1. **Engine:** if C beats the better of A and B on time to first chart for views 1 and 4 by at least 300 ms, drop DuckDB‑WASM and build the query layer in TypeScript. DuckDB's remaining advantage would be SQL, not speed, and the app doesn't need ad‑hoc SQL today. Otherwise keep DuckDB‑WASM.
2. **Layout (only if DuckDB is kept):** keep A unless B is within 100 ms of A on time to first chart for views 1 and 4. If it is, prefer B for its simpler file layout.

Whichever wins, the UI only talks to a `loadView(theme, geoLevel)` / `queryView(params)` interface, so swapping the engine or layout later changes one module. The Parquet files, the golden tests and the URL state stay the same.

### Phase 0 results (2026‑10‑18)

**How it was run:**
- Code: `web/bench/` (`bench.ts` and `index.html`), driven by `web/bench/run-bench.mjs`.
- Browser: headless Chrome 152 on the development Mac, one fresh profile per run.
- Server: serves the production build with gzip for JS, WASM and JSON (Parquet is already zstd), and supports HTTP Range for contender B.
- Throttling: optional, applied at the server and shared across all responses, so the DuckDB worker's downloads are slowed too.
- **First visit:** empty cache. **Repeat visit:** the engine comes from the disk cache. Data files are cache‑busted on every load.
- Checksums of the plotted rows were identical across A, B and C for every step.
- Raw medians are in `web/bench/results/*.json`.

**Download sizes (production build):**

| | DuckDB‑WASM (A, B) | hyparquet (C) |
|---|---|---|
| Engine / module | 34.2 MB `.wasm` (7.8 MB gzipped) + 0.77 MB worker + 48 KB JS glue | 62 KB + 114 KB JS (19 KB + 75 KB gzipped) |
| Data for view 1 | 141 KB (A) / byte ranges of a 1.08 MB file (B) | 141 KB |

Steps follow the bench session: view 1 cold, view 1 again (warm), view 4 (switch to PT), view 2 (new theme), view 3 (CSD drill). Medians are in ms; the "session" column is the five steps added together.

*Unthrottled (5 runs):*

| | View 1 cold | View 1 warm | View 4 | View 2 | View 3 | Session |
|---|---|---|---|---|---|---|
| A, first visit | 1,081 | 6 | 267 | 393 | 114 | 1,861 |
| B, first visit | 932 | 30 | 14 | 24 | 14 | 1,014 |
| **C, first visit** | **145** | 9 | 217 | 273 | 89 | **733** |
| A, repeat visit | 704 | 5 | 265 | 391 | 114 | 1,479 |
| B, repeat visit | 585 | 30 | 14 | 24 | 14 | 667 |
| **C, repeat visit** | **118** | 9 | 196 | 294 | 87 | 704 |

*Throttled to 9 Mbps and 60 ms latency, roughly a good 4G connection (3 runs):*

| | View 1 cold | View 1 warm | View 4 | View 2 | View 3 | Session |
|---|---|---|---|---|---|---|
| A, first visit | 8,718 | 5 | 735 | 985 | 376 | 10,819 |
| B, first visit | 9,378 | 30 | 14 | 1,231 | 19 | 10,672 |
| **C, first visit** | **509** | 9 | 676 | 790 | 338 | **2,322** |
| A, repeat visit | 908 | 6 | 723 | 985 | 376 | 2,998 |
| B, repeat visit | 1,655 | 30 | 14 | 1,229 | 19 | 2,947 |
| **C, repeat visit** | **342** | 9 | 650 | 793 | 332 | **2,126** |

**What the numbers say:**
- **The engine download dominates the first visit.** On 4G, DuckDB spends about 7.75 s booting, almost all of it downloading the 7.8 MB WASM, before it can answer anything. C's first chart arrives in about 0.5 s.
- **Once data is loaded, everything is fast.** Queries take 5–30 ms for every contender.
- **B's quick switches are an artifact of its file size.** B's first query pulled most of the 1.08 MB permanent residents file over HTTP ranges, so later views of that theme were already local (14–19 ms). The cost moved into view 1, not away.
- **C's switch cost is fetch plus JavaScript decode.** On 4G that's about 440 ms to fetch the PT file and about 200 ms to decode it in JS (DuckDB decodes the same file in about 280 ms). Prefetching PT when the browser is idle, which the loading strategy already includes, hides most of this.

**Decision rules applied:**
- **Rule 1** asks whether C beats the better of A and B on time to first chart by at least 300 ms for views 1 and 4 under throttling.
  - View 1: met by a wide margin. C takes 509 ms; the best of A and B takes 8,718 ms.
  - View 4: **not met** as written. B takes 14 ms and C 676 ms, but only because B had already downloaded the theme while taking 9.4 s over view 1.
  - Across the whole session, C is about 8.3 s faster on a first visit and about 0.8 s faster on a repeat visit.
- **Rule 2** (layout) only applies if DuckDB is kept.

**Recommendation: adopt C (hyparquet + TypeScript) and drop DuckDB‑WASM.** Rule 1 as written didn't anticipate B front‑loading a whole theme during view 1. On the measure the rule was meant to protect (how long people wait), C wins every first‑visit and repeat‑visit session, on every connection tested. Keep the theme × geo_level layout (A's files, which C also reads).

**Not yet covered:**
- A real iPhone in Safari.
- CPU slowdown. Chrome's CPU throttling applies to the page, not to DuckDB's worker, so it couldn't be applied fairly. C should move its decoding into a worker in production anyway, and then both can be throttled the same way.

Repeating this on an iPhone, by opening `/bench/?c=A`, `?c=C` etc. from a phone on the same network, is a 15‑minute check before Phase 2.

## 7. Risks and mitigations

- **First‑load weight (DuckDB‑WASM 7.8 MB gzipped; see Phase 0 results):** the landing cards and each theme's first chart render from pre‑aggregated JSON, and the engine loads in a worker while the user reads. Hashed filenames make repeat visits instant. If the engine is still too slow on the first control change, Phase 0's contender C removes it entirely.
- **Pre‑aggregated JSON drifting from live queries:** the default views are generated by the R functions and asserted equal to the query layer in the golden tests, so a mismatch fails CI.
- **Hand‑written aggregation (if C wins):** the logic lives in TypeScript rather than SQL, but it's held to the same parity suite. Bringing DuckDB back later for ad‑hoc queries would only change the query module.
- **Silent logic drift from the R version:** the golden‑file parity suite in CI, regenerated with each data refresh.
- **Safari/iOS memory:** keep about 4 (theme, geo_level) tables in memory and drop the least recently used. Total data is 2.8 MB, so the risk is low.
- **Lag when switching geographic level:** the first switch to PT, CMA, CD or CSD fetches a new file. PT is prefetched when the browser is idle; the smaller levels are under 200 KB and show a skeleton while loading.
- **Ongoing content work (descriptions, events):** computed placeholders keep the facts current, and the coverage check flags gaps automatically.
- **Two codebases during the overlap:** the R pipeline is shared. Only the Shiny UI is retired, and only after phase 6.

## 8. Decisions for you

1. ~~**Framework**~~: decided 2026‑10‑18, Svelte 5.
2. ~~**Query engine**~~: decided 2026‑10‑18, hyparquet + TypeScript.
3. **Hosting:** GitHub Pages (simplest if the repo moves to GitHub) or Cloudflare Pages (better caching and headers).
4. **Description authoring:** YAML in the repo (recommended) or an Excel sheet like `label_overrides.xlsx`.
5. **Event annotations:** include them (needs your curation) or leave them out.
6. **Old Shiny deployments** (shinyapps.io and Posit Connect Cloud): redirect them or keep them running.
7. **Data in git:** `web/public/data/` (2.9 MB of Parquet plus JSON) and `web/tests/golden/` (11 MB) are derived from the gitignored database, but CI and GitHub Pages need them. Options: commit them on each refresh, or publish them from a release step. Committing is simplest; the golden files could be gzipped.
