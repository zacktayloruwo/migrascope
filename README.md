# Canadian Immigration Statistics

Pulls IRCC's monthly "Open Data" cumulative update tables (permanent and temporary migrant admissions) and IRB refugee-decision tables from open.canada.ca, loads them into DuckDB, and serves them through a Shiny app with a longitudinal bar chart per dataset.

## Datasets tracked

IRCC "Monthly Update" datasets (`R/ingest_utils.R`, `ircc_datasets`):

| Slug | CKAN dataset |
|----|----|
| `temporary_workers` | [Temporary Residents: TFWP and IMP Work Permit Holders](https://open.canada.ca/data/en/dataset/360024f2-17e9-4558-bfc1-3616485d65b9) |
| `asylum_claimants` | [Asylum Claimants](https://open.canada.ca/data/en/dataset/b6cbcf4d-f763-4924-a2fb-8cc4a06e3de4) |
| `study_permit_holders` | [Temporary Residents: Study Permit Holders](https://open.canada.ca/data/en/dataset/90115b00-f9b8-49e8-afa3-b4cff8facaee) |
| `tr_to_pr_transition` | [Transition from Temporary Resident to Permanent Resident Status](https://open.canada.ca/data/en/dataset/1b026aab-edb3-4d5d-8231-270a09ed4e82) |
| `permanent_residents` | [Permanent Residents](https://open.canada.ca/data/en/dataset/f7e5498e-0ad8-4417-85c9-9b8aff9b9eda) |

Immigration and Refugee Board (IRB) datasets (`R/ingest_utils.R`, `irb_datasets`) - a different organization and a different resource-publishing convention (see below):

| Slug | CKAN dataset |
|----|----|
| `rpd_decisions` | [Refugee Protection Division (RPD) Decisions](https://open.canada.ca/data/en/dataset/6e47f705-71ed-41f0-8fd5-d1a8508a3b63) |
| `rpd_1997_2021` | [Open Dataset Request 833195 - RPD decisions from 1997-2021 by outcome and province of claimant](https://open.canada.ca/data/en/dataset/bf181c11-8c67-4b98-a002-c0f016b2e43c) |

## How it works

0.  **`data-raw/00_discover_datasets.R`** *(optional, read-only)* — queries CKAN's `package_search` API for every "... – Monthly IRCC Updates" dataset under the IRCC/CIC organization (the same catalogue behind [the HTML search page](https://search.open.canada.ca/opendata/?owner_org=cic&search_text=IRCC+Monthly+Updates), queried directly rather than scraped) and writes `data-raw/discovered_datasets.csv`. It flags any active dataset not yet listed in `ircc_datasets` (`R/ingest_utils.R`) - as of writing that's Afghan Refugees (Permanent Resident Admissions), Express Entry Permanent Residents, Express Entry-Invited Candidates, and Operational Processing. These are IRCC "Monthly Update" datasets but outside this project's scope (general permanent/temporary admission counts); add a dataset's id to `ircc_datasets` if you decide it belongs here. This step never changes what gets downloaded on its own.

1.  **`data-raw/01_build_manifest.R`** — queries the CKAN `package_show` API for each dataset above and writes `data-raw/manifest.csv`: one row per distinct data table.

    - For IRCC datasets: where the same table is published in both Excel and CSV, the Excel version is kept (the CSV twins have some values rounded or suppressed to protect privacy; the Excel exports don't). French-language resources and non-data HTML resources (documentation landing pages) are dropped. Where a table is genuinely only published as CSV (or `.xls`), that's what's kept.
    - For `rpd_decisions`: IRB republishes the *same* cumulative table under a newly dated resource each quarter (e.g. "... 2025 Q4", "... 2026 Q1") instead of updating one stable URL, so the manifest picks out only the latest quarter's English resource (`build_rpd_decisions_manifest()` in `R/ingest_utils.R`) rather than deduping by name. Its Data Dictionary resource is kept too but flagged as documentation (see step 3) - as of writing its URL on canada.ca is dead (404); it's non-essential since the table's columns are already plain English.
    - For `rpd_1997_2021`: a one-off historical extract, handled the same way as an IRCC ad-hoc table (single static resource, EN + XLSX preferred).

2.  **`data-raw/02_download_data.R`** — reads the manifest and downloads every file into `data-raw/downloads/<dataset>/`, named `<resource_id>__<table-name-slug>.<ext>`. Before touching the network, each resource's CKAN `metadata_modified` timestamp (`last_modified_ckan` in the manifest) is compared against the value recorded the last time it was successfully downloaded; if unchanged and the local file still exists, the download is skipped entirely (`skipped_unchanged`). Otherwise the file is fetched and hash-compared against the existing copy as a second safety net. A summary is written to `data-raw/download_log.csv` (status: `new` / `updated` / `unchanged` / `skipped_unchanged` / `error`).

3.  **`data-raw/03_process_tables.R`** — turns every downloaded raw file into tidy long + wide CSVs under `data/processed/<dataset>/`. Three source shapes are handled (see `R/process_utils.R`):

    - **IRCC flat CSVs** are already one row per (year, quarter, month, ...dimensions) with a `TOTAL` value column and parallel `FR_` columns - these just get the French columns dropped and the period parsed.
    - **IRCC pivot Excel workbooks** (most `.xlsx`/`.xls` files, sometimes several sheets each) have a title row, 1-3 header rows encoding a Year / Quarter / Month hierarchy across columns, and 1-4 leading row-header columns encoding a nested row category (e.g. Province \> Immigration Category \> Group \> Component) where a subtotal row is written as a *trailing* footer for the detail rows above it (e.g. "Ontario Total" closes out the block, it doesn't introduce it). Each sheet is parsed into its own table.
    - **IRB tables** (`rpd_decisions`, `rpd_1997_2021`) are much simpler: a single header row of plain English column names, one row per category x Year already, annual granularity only (no quarter/month). The Data Dictionary resource is skipped here (status `docs` in the log) since it isn't a data table.

    All three shapes produce a common tidy schema: one row per (row-category combination x period), with `level_1..level_k` for IRCC pivot tables (the reconstructed nested row category, "Total" suffixes stripped) or plain named dimension columns for flat/IRB tables, `is_row_subtotal` and `is_period_subtotal` flags (so you can filter out subtotal rows/columns to avoid double-counting), `value` (numeric, `NA` when suppressed), and a `suppressed` flag for the "--" code both IRCC and IRB use (values between 0 and 5, withheld to prevent identification). The wide CSV is the same table pivoted so each period is its own column. A summary is written to `data-raw/process_log.csv`.

4.  **`data-raw/04_validate_tables.R`** — runs internal-consistency checks (see `R/validate_utils.R`) against every tidy long table: column-wise (do a row's own months sum to its quarter total, quarters to its year total?) and row-wise (do a nested pivot table's detail rows sum to their subtotal, and subtotals to the grand total?). Both account for IRCC/IRB's rounding-to-5 and "--" suppression with a tolerance band rather than requiring exact equality. Results go to `data-raw/validation_{period,row}_results.{csv,rds}`. This step also detects and reclassifies "stock"-type tables (e.g. "with a valid permit" snapshots, where months aren't additive) so they don't show up as false-positive anomalies - see `reports/data_quality_report.qmd` for the full methodology and findings.

5.  **`reports/data_quality_report.qmd`** — a Quarto report summarizing the validation results: overall pass/anomaly/not-checkable rates, the tables with the most flagged anomalies, the largest distinct anomalies, and a writeup of two patterns found by tracing anomalies back to their source spreadsheets (non-additive "stock" tables, and a couple of sheets that append a second, differently-grouped breakdown below the main table). Render with:

    ``` sh
    quarto render reports/data_quality_report.qmd --to pdf
    ```

6.  **`data-raw/05_build_duckdb.R`** — normalizes every processed long table (see `R/duckdb_utils.R`) into one shared schema and loads it into `app/data/immigration.duckdb`, the app's data source (written straight into the app's own `data/` directory - see "Layout" below for why):

    - A `facts` table with `level_1..level_5` (padded with `NA` past a table's actual depth), `row_level`, `is_row_subtotal`, and the same period/value columns as the processed CSVs - both source shapes (IRCC pivot tables and flat/IRB tables) end up in this one shape, so the app doesn't need per-table special-casing.
    - A `catalog` table, one row per source table, recording what its `level_1..level_5` actually mean (real dimension names for flat tables; a best-effort guess parsed from the table title for pivot tables, e.g. "... by Province/Territory and Immigration Category" → `("Province/Territory", "Immigration Category")`), which temporal granularities it has data for, its year range, and whether it's a "stock" table (same detection as `reclassify_stock_tables()`).
    - `rpd_decisions` (2013-2026, by country of persecution) and `rpd_1997_2021` (1997-2021, by province of residence) are both normalized individually as usual (so their own geography breakdowns stay browsable) *and* relabeled from their own `rpd_decisions`/ `rpd_1997_2021` datasets into one shared "Refugees" theme, alongside a third, synthetic table that combines them into a single continuous 1997-2026 series (`R/duckdb_utils.R::build_refugees_table()`). The two source tables' row dimensions differ in kind (country vs. province), so that third table keeps only what both share: Outcome (Positive/Negative → Accepted/Rejected, matching `rpd_1997_2021`'s vocabulary) by year. For the overlapping years (2013-2021) the two sources' outcome totals don't match exactly - `rpd_decisions`' much finer country-level breakdown suppresses more small cells, understating its totals by a few percent up to \~30% for some year/outcome pairs (see `data-raw/refugees_merge_overlap_check.csv` after running this step) - so the combined table uses `rpd_1997_2021` (fewer suppressed cells) through 2021 and `rpd_decisions` from 2022 on, never both for the same year. All three tables show up as separate "Data table" choices under the Refugees theme.
    - Also copies `data-raw/manifest.csv` to `app/data/source_manifest.csv`
      - the app's source-citation feature (below) reads that copy rather than reaching into `data-raw/` at runtime, keeping `app/` self-contained.

7.  **`data-raw/06_build_label_lookups.R`** — (re)generates `app/data/label_overrides.xlsx`, one hand-editable Excel Table covering both overrides: one row per `table_id` (a `Series (custom)` cell, overriding `derive_series_label()`'s guess for that one table) plus one additional row per non-geographic breakdown level that table has (a `Breakdown item (custom)` cell, keyed by `(table_id, Breakdown item (auto))` so the *same* raw label can be corrected differently in different tables - not one global rename). Also includes a read-only `Source table title` column (the same full citation title `07` computes) so an editor can tell which real source table an opaque `table_id` corresponds to. Unlike the old two-file version, this script doesn't just write an editable reference file for app.R to read at startup - it **bakes** the resolved (custom-if-present-else-auto) values straight into `app/data/immigration.duckdb`'s `catalog` table (a `series_label` column, and the corrected `level_N_label` cell(s)), so corrections are applied at database-creation time, not live in the app. Hand edits survive a re-run (matched by `table_id` / `(table_id, Breakdown item (auto))` respectively). Must run after `05_build_duckdb.R`, not standalone - see the script's header comment.

8.  **`data-raw/07_build_series_reference.R`** — (re)generates `reports/series_reference.xlsx`, a read-only reference table of every Series the app can show: one row per (Series × Geographic Aggregation level × Temporal Aggregation level), with that Series' Theme, available Breakdown items, and the full source table title exactly as it appears in the app's own citation (not `catalog$table_title`, which can carry an internal multi-sheet suffix the citation doesn't show). Reads straight from `catalog` (already reflecting `06`'s baked-in overrides), same as the app - it's a snapshot of what a user actually sees, not consumed by the app itself, just a standalone report for humans.

9.  **`data-raw/08_build_series_facts.R`** — builds `series_facts`, the table the app actually queries: one row per genuinely distinct (theme, series, breakdown facet/depth, geography, period) fact, already deduplicated across every raw source table that contributes to it. This is the fix for a problem query-time table selection couldn't solve - many tables within one series independently publish the same underlying total (e.g. a province's grand total, once broken down by Sex, once by Occupation, once by CD/CSD), each with its own suppression pattern, so the number shown used to depend on which sibling table happened to get picked. Here, every geography level a series supports is built by pulling each qualifying member table's own published subtotal rows at that depth and, cell by cell, keeping the largest value across every contributing table (suppression only ever removes value from a sum, never inflates it, so the least-suppressed sibling has the most complete number) - the winning `table_id` is kept in `source_table_id` for traceability. Raw `facts`/`catalog` are untouched underneath; this reads them and writes a new, additional table. Must run after `06_build_label_lookups.R`.

Run from the project root:

``` r
source("data-raw/00_discover_datasets.R")  # optional: check for new IRCC datasets
source("data-raw/01_build_manifest.R")
source("data-raw/02_download_data.R")
source("data-raw/03_process_tables.R")
source("data-raw/04_validate_tables.R")
source("data-raw/05_build_duckdb.R")
source("data-raw/06_build_label_lookups.R")
source("data-raw/07_build_series_reference.R")
source("data-raw/08_build_series_facts.R")
source("data-raw/10_export_web.R")         # Parquet + JSON for the static web app (web/), see docs/wasm-port-plan.md
source("data-raw/11_export_golden.R")      # golden files for the web app's parity tests (cd web && npm test)
```

``` sh
quarto render reports/data_quality_report.qmd --to pdf
```

## Running the app

The app lives entirely under `app/` - a self-contained bundle with its own `app.R`, `R/`, `www/`, `ABOUT.md`, and `data/` (a copy of the data-prep pipeline's output: `immigration.duckdb` and `source_manifest.csv` - `immigration.duckdb`'s `catalog` table already has every hand-typed name correction baked in, so the app doesn't read `label_overrides.xlsx` at all). It doesn't read anything from outside `app/` at runtime, on purpose - see "Layout" and "Deploying to shinyapps.io" below.

``` r
shiny::runApp("app")
```

The top bar has two buttons: **About** swaps the main panel for a rendered copy of `app/ABOUT.md` (a user-facing description of the app and its data, as opposed to this developer-facing README), and **Visualize** swaps back to the chart. Both panels stay mounted in the DOM the whole time (`bslib::navset_hidden()`, switched via `bslib::nav_select()`) so returning to the chart doesn't lose or recompute the current selection.

A **Theme** pulldown at the top of the sidebar selects the dataset - the `temporary_workers` ingest dataset is split into two themes, International Mobility Program and Temporary Foreign Worker Program (`app/R/app_utils.R::split_temporary_workers()`), since those are two distinct programs users generally want to look at separately. The rest of the sidebar reacts to the selected theme:

- **Data table** — which specific breakdown to view (e.g. "by Province and Gender"), from the selected theme's tables in the catalog.
- **Temporal aggregation** — Monthly / Quarterly / Annual, limited to what the selected table actually supports (most annual-only tables, like the IRB ones or "on December 31st" snapshots, only offer Annual).
- **Category breakdown** — "Total (no breakdown)" or one of the table's nested levels (e.g. Province, or Province \> Immigration Category). Always computed from the finest-grain leaf rows (never from published subtotal rows, which don't exist at every level for every table) so any level can be chosen freely.
- **Max categories shown** — folds all but the top N categories (by total value) into "Other" so a level with hundreds of distinct values (e.g. countries, census subdivisions) stays readable.

For "stock" tables (e.g. "with a valid permit" snapshots - see the data quality report), Quarterly/Annual views show the latest available month's value *per leaf entity, summed up to the display category* - not a sum of months, which would overcount. The chart title flags these tables explicitly. See `app/R/app_utils.R::aggregate_series()`.

The bottom of the plot card cites the displayed table's original CKAN resource(s): publishing agency (IRCC or IRB), a link to the source Excel/CSV file with the date CKAN last reported it modified ("last updated" - `last_modified_ckan`, straight from `app/data/source_manifest.csv` - a copy of `data-raw/manifest.csv`, the same field the download pipeline uses to detect changed resources), and a link to its Open Government Portal dataset page. A trailing "Last accessed" date is just `Sys.Date()` at render time - when the citation was generated, not when the local data snapshot was downloaded (that's `data-raw/download_log.csv`, per the Refreshing section below). Built from `app/data/source_manifest.csv` at startup, joined to the displayed table via the hash prefix in its `table_id` (`app/R/app_utils.R::extract_table_hash()` / `build_source_lookup()`). The merged Refugees table has no single source resource of its own, so it cites both of its sibling tables' resources instead (`app/app.R`'s `table_citation_ui()`).

`.claude/launch.json` defines a `shiny-app` preview config (`shiny::runApp('app', port = 8931)`) for use with an IDE's preview/dev-server tooling.

## Refreshing

IRCC republishes its files roughly monthly; IRB republishes `rpd_decisions` roughly quarterly (`rpd_1997_2021` is a static one-off, it won't change). To pick up the latest data (and any newly-added tables), just re-run the scripts above in order — `01_build_manifest.R` re-derives the table list from the live CKAN API in case a new breakdown was added, `02_download_data.R` skips resources whose CKAN timestamp hasn't changed (and hash-compares anything it does fetch), `03_process_tables.R` reprocesses everything (cheap - a few minutes for all tables), `04_validate_tables.R` re-runs the consistency checks (the slowest step - several minutes, dominated by a handful of tables with 500k+ rows), `05_build_duckdb.R` rebuilds the app's database (a couple of minutes), `06_build_label_lookups.R` refreshes `label_overrides.xlsx` - adding rows for any newly-added table/breakdown without touching hand-edited "(custom)" values for existing ones - *and* bakes the resolved values back into `immigration.duckdb`'s `catalog` table, `07_build_series_reference.R` regenerates the `reports/series_reference.xlsx` snapshot from that same `catalog`, and `08_build_series_facts.R` rebuilds `series_facts` - the deduplicated table the app actually reads - from `catalog`/`facts`. The running Shiny app picks up a rebuilt `app/data/immigration.duckdb` on its next restart (it opens one read-only connection at startup, and only ever queries `series_facts`) - `label_overrides.xlsx` isn't read by the app at all, and `series_reference.xlsx` is a standalone report, not read by the app either.

## Layout

The repo is split into two independent halves: a **data-prep pipeline** (everything below except `app/`) that turns IRCC/IRB open data into a DuckDB database, and a **Shiny app** (`app/`) that only ever reads that database plus two small derived files. The app doesn't `source()` or read anything from outside `app/` - that split exists so `app/` alone can be deployed to shinyapps.io without dragging along raw downloads, processing scripts, or validation caches (see "Deploying to shinyapps.io" below).

```         
app/                                    # self-contained Shiny app bundle - deploy THIS directory
app/app.R                               # Shiny app
app/ABOUT.md                            # user-facing "About" content, rendered in-app via the About button
app/www/custom.css                      # text styling for every labelled element in the app (linked from app.R's <head>)
app/R/app_utils.R                       # app query/aggregation helpers (series_facts -> plot data); also sourced by data-raw/06 and 08 for shared pipeline helpers (derive_theme_dimension_map(), table_geo_subtotals(), etc.)
app/data/immigration.duckdb             # app database, gitignored (regenerate via 05_build_duckdb.R -> 06_build_label_lookups.R -> 08_build_series_facts.R) - the app only ever queries `series_facts`, the deduplicated table 08 builds; `facts`/`catalog` are the raw layer underneath it
app/data/label_overrides.xlsx           # editable Series/Breakdown item name overrides (see data-raw/06_build_label_lookups.R) - tracked in git, hand edits preserved on regen, NOT read by the app (baked into immigration.duckdb's catalog table instead)
app/data/source_manifest.csv            # copy of data-raw/manifest.csv, for the in-app source citation - tracked in git, regenerated by data-raw/05
.claude/launch.json                     # preview/dev-server config for app/app.R
R/ingest_utils.R                        # manifest-building + dataset-discovery helpers
R/process_utils.R                       # raw-file -> tidy long/wide parsing helpers
R/validate_utils.R                      # internal-consistency check helpers
R/duckdb_utils.R                        # tidy-table -> unified schema normalization for DuckDB
data-raw/discovered_datasets.csv        # result of the most recent discovery run
data-raw/manifest.csv                   # one row per data table (dataset, name, format, url)
data-raw/download_log.csv               # result of the most recent download run
data-raw/process_log.csv                # result of the most recent processing run
data-raw/validation_period_results.*    # column-wise (within-row) check results - gitignored, the .csv forms are 100MB+ (regenerate via 04_validate_tables.R)
data-raw/validation_row_results.*       # row-wise (within-period) check results - gitignored, same reason
data-raw/refugees_merge_overlap_check.csv # rpd_decisions vs rpd_1997_2021 outcome totals for their overlap years (05_build_duckdb.R)
data-raw/downloads/                     # raw Excel/CSV files, gitignored (regenerate via the scripts above)
data/processed/<dataset>/               # tidy long + wide CSVs, gitignored (regenerate via 03_process_tables.R) - a data-prep intermediate, not read by the app
reports/data_quality_report.qmd         # validation report source
reports/data_quality_report.pdf         # rendered report (regenerate via quarto render)
reports/series_reference.xlsx           # every Series' Theme/Breakdown items/Geographic+Temporal Aggregation/citation title (regenerate via data-raw/07_build_series_reference.R) - not read by the app
```

## Deploying to shinyapps.io

Because `app/` is self-contained, deployment is just pointing `rsconnect` at that one directory instead of the repo root:

``` r
rsconnect::deployApp("app")
```

This uploads only `app/app.R`, `app/R/`, `app/www/`, `app/ABOUT.md`, and `app/data/` - none of the data-prep scripts, raw downloads, or validation artifacts. Run the "Refreshing" steps above and re-deploy whenever the underlying data changes; the deployed app doesn't fetch anything live.

## Known limitations / next steps

- The app's category-level labels (e.g. "Province/Territory", "Immigration Category") are a best-effort parse of each table's title (`guess_level_labels()` in `R/duckdb_utils.R`) for pivot tables, since the underlying processed CSVs only have generic `level_1..level_k` columns. Most read cleanly; a few fall back to generic "Category Level N" where the title doesn't spell out every nesting level.
- The app's "stock table" detection (`R/duckdb_utils.R`, mirroring `R/validate_utils.R::reclassify_stock_tables()`) is a statistical heuristic (month-sum consistently \~3x the quarter total), not a hardcoded list - a genuinely new stock-type table IRCC adds later should be caught automatically, but it's worth spot-checking after a refresh (`catalog$is_stock` in the DuckDB, or just watch for an implausibly large jump when switching a table from Monthly to Annual).
- See `reports/data_quality_report.pdf` for validated findings on where the data does and doesn't check out internally, including an "appended second breakdown" pattern in a few source sheets that the row-hierarchy parser doesn't yet detect (documented there rather than duplicated here).
- The parser was validated against representative tables from every dataset (flat CSVs; 1-4 level nested pivots; annual-snapshot and percentage tables; multi-sheet workbooks) but not exhaustively against all 87 processed outputs - spot-check a table against its source file before relying on it for anything published.
- `level_1..level_k` column names are generic (not renamed per table to e.g. `province`/`immigration_category`) since the nesting differs table to table; check the sheet title (kept as an attribute when processing interactively via `process_pivot_excel()`) or the source file to know what each level represents.
- **Duplicate-table audit (resolved):** a post-hoc check compared every pair of same-dataset tables by normalized title similarity, then verified candidates against their actual yearly totals (not just title similarity - see the asylum_claimants entry below for why that distinction matters). Two were confirmed as the same table published under two names that `normalize_table_key()` (`R/ingest_utils.R`) didn't yet collapse - both fixed there:
  - *Permanent Residents by Province/Territory and Immigration Category*: an XLSX resource ("Permanent Residents", plural, capitalized) and a CSV resource ("Permanent resident", singular, lowercase) - same table, differing only by pluralization/case. Yearly totals tracked 5-13% apart (the CSV twin, like other CSV/XLSX pairs in this pipeline, rounds/suppresses more), confirming they're the same underlying data. Fixed by normalizing "resident(s)" before the format-preference dedup, so the XLSX copy is kept and the CSV twin is dropped.
  - *Study Permit Holders by Province/Territory and Study Level*: two resources differing only by an en-dash/hyphen and a serial comma ("...study level and year..." vs "...study level, and year..."). Yearly totals matched within 0-0.8% - closer to a straight republish than the pair above. Fixed by stripping commas before computing the dedup key.

  A third case turned out not to be a manifest-level duplicate at all: the four "French-Speaking Permanent Residents by Province/Territory and \<X\>" workbooks (Age Group / CMA / Gender / Immigration Category - four genuinely distinct resources, each with its own unique breakdown) each *also* embed an identical sheet literally named "PR - PT" (a province-only total, with year-by-year values confirmed identical across all four). Since the manifest only sees whole resources, this couldn't be deduplicated in `01_build_manifest.R` - it's fixed one stage later, in `03_process_tables.R`'s `DUPLICATE_SHEETS` list, which keeps that sheet from exactly one of the four workbooks (the Age Group one) and skips it in the other three (logged as `skipped_duplicate_sheet` in `process_log.csv`).
- The two `asylum_claimants` tables titled "...Claim Month" (`34c502f9`, an XLSX pivot resource) and "...Claim Year" (`ec417b64`, a flat CSV resource) look like a granularity pair but aren't: both actually contain month-level data internally (that's why the app offers Monthly/Quarterly/ Annual for both), yet for the same year/province/gender combination the "Claim Month" table's totals run almost exactly 3x higher than "Claim Year"'s - a pattern that also holds for the equivalent Age-breakdown pair (`46bee0ae` vs `bdac348b`), so it's structural, not a one-off error. Most likely the two are counting different units (e.g. individual claimants vs. claims/cases, where one claim can cover several dependents), but this isn't confirmed against an official IRCC data dictionary - treat both tables' absolute totals with caution until it is.
- The RPD Data Dictionary resource's URL (`canada.ca/.../RPD-Open-Data-Dictionary-July2018-eng.xlsx`) is dead on IRB's own site (404) - `02_download_data.R` will always log it as `error`. Non-essential: the `rpd_decisions` table's columns are already plain English (Country of Persecution, Year, Outcome, Total).
