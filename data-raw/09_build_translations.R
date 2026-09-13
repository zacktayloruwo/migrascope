# Builds/refreshes app/data/translation_overrides.xlsx and bakes the
# resolved (custom-if-present-else-auto) English->French pairs into
# app/data/immigration.duckdb's `category_translations` table - the lookup
# app.R's translate_vec() (app/R/app_utils.R) reads at render time to show
# French category text (theme/series/facet/breakdown_1/2/3 display labels)
# without changing the English text that stays the canonical query key
# throughout data-raw/08_build_series_facts.R and app/R/app_utils.R.
#
# This step (Phase 2 of the bilingual rollout) covers ONLY the "flat CSV"
# source shape, whose every EN dimension column already has a genuine
# French-translation sibling column in the very same downloaded file
# (`FR_*`, carried through as `<dimension>__fr_label` by
# R/process_utils.R::process_flat_csv() - see that function's own comment
# for how the FR_ column is matched to its EN sibling by position). No
# alignment risk at all here since it's the same row, same file - unlike
# the pivot Excel/IRB case (data-raw/09_harvest_fr_translations.R), which
# needs to fetch and align a genuinely separate French document.
#
# Regenerating is non-destructive: existing "(custom)" values are preserved
# (matched by (en_text, context, table_id)), mirroring
# data-raw/06_build_label_lookups.R's auto/custom pattern exactly.
#
# IMPORTANT: run after data-raw/03_process_tables.R (needs the
# `__fr_label` columns in data/processed/) and app/data/immigration.duckdb
# must already exist (05_build_duckdb.R) - this script only reads catalog
# from it to know which table_ids are flat-CSV shaped, and writes a new
# table into the same database.

library(DBI)
library(duckdb)
library(dplyr)
library(openxlsx)
library(readxl)

DB_PATH <- "app/data/immigration.duckdb"
OUT_PATH <- "app/data/translation_overrides.xlsx"

if (!file.exists(DB_PATH)) {
  stop("app/data/immigration.duckdb not found - run data-raw/05_build_duckdb.R first")
}

con <- dbConnect(duckdb(), DB_PATH, read_only = TRUE)
catalog <- dbGetQuery(con, "select table_id, dataset, table_title from catalog")
dbDisconnect(con, shutdown = TRUE)

# ---- harvest (en_text, fr_text) pairs from every flat-CSV processed table --
long_files <- fs::dir_ls("data/processed", regexp = "_long\\.csv$", recurse = TRUE)

table_id_from_path <- function(path) {
  parts <- fs::path_split(path)[[1]]
  n <- length(parts)
  paste(parts[n - 1], sub("_long\\.csv$", "", parts[n]), sep = "/")
}

harvest_one <- function(path) {
  table_id <- table_id_from_path(path)
  header <- names(readr::read_csv(path, n_max = 0, show_col_types = FALSE))
  fr_cols <- grep("__fr_label$", header, value = TRUE)
  if (length(fr_cols) == 0) return(NULL)

  en_cols <- sub("__fr_label$", "", fr_cols)
  df <- readr::read_csv(path, col_types = readr::cols(.default = "c"),
                         col_select = dplyr::all_of(c(en_cols, fr_cols)))

  purrr::map_dfr(seq_along(en_cols), function(i) {
    en_col <- en_cols[i]; fr_col <- fr_cols[i]
    tibble::tibble(en_text = df[[en_col]], fr_text = df[[fr_col]], table_id = table_id) |>
      dplyr::filter(!is.na(.data$en_text), !is.na(.data$fr_text),
                     nzchar(.data$en_text), nzchar(.data$fr_text)) |>
      dplyr::distinct()
  })
}

cli::cli_h1("Harvesting EN->FR breakdown-value pairs from flat-CSV processed tables")
pairs <- purrr::map_dfr(long_files, harvest_one)

if (nrow(pairs) == 0) {
  cli::cli_alert_warning("No flat-CSV __fr_label columns found - nothing to harvest yet")
}

# A breakdown value's series_facts *context* (breakdown_1/2/3) depends on
# where its source column ends up in that table's own facet nesting (see
# data-raw/08_build_series_facts.R::table_shape()) - replicating that
# position logic here isn't worth it for what's fundamentally a small,
# mostly-unambiguous vocabulary (province/gender/category names), so each
# pair is written under all three breakdown contexts; translate_vec()'s
# lookup is keyed by (en_text, context, table_id) so this costs a little
# redundancy, not correctness.
BREAKDOWN_CONTEXTS <- c("breakdown_1", "breakdown_2", "breakdown_3")
pairs_expanded <- if (nrow(pairs) > 0) {
  tidyr::crossing(pairs, context = BREAKDOWN_CONTEXTS)
} else {
  tibble::tibble(en_text = character(), fr_text = character(),
                  table_id = character(), context = character())
}

# Every harvested pair is initially scoped to the table_id it came from -
# but translate_vec() (app/R/app_utils.R) is mostly called WITHOUT a
# table_id (a displayed series/facet/breakdown value in the app can come
# from any of several contributing tables), so it only ever checks its
# *unscoped* (table_id IS NULL) fallback in practice. A term that every
# table agreeing on the same (en_text, context) -> fr_text mapping is
# therefore promoted to one global (table_id = NA) row instead of staying
# needlessly duplicated per table - this is the common case (per the
# ~1,700x-reuse finding in the original bilingual-scoping investigation).
# A term where tables genuinely *disagree* keeps its per-table_id rows
# (so app.R calls that DO pass a table_id can still resolve correctly) and
# is logged for manual review rather than silently picking one.
term_agreement <- pairs_expanded |>
  dplyr::distinct(.data$en_text, .data$context, .data$table_id, .data$fr_text) |>
  dplyr::group_by(.data$en_text, .data$context) |>
  dplyr::summarise(n_distinct_fr = dplyr::n_distinct(.data$fr_text),
                     fr_text = dplyr::first(.data$fr_text), .groups = "drop")

conflicting_terms <- term_agreement |> dplyr::filter(.data$n_distinct_fr > 1)
if (nrow(conflicting_terms) > 0) {
  conflicts <- pairs_expanded |>
    dplyr::semi_join(conflicting_terms, by = c("en_text", "context")) |>
    dplyr::distinct(.data$en_text, .data$context, .data$table_id, .data$fr_text)
  fs::dir_create("data-raw")
  readr::write_csv(conflicts, "data-raw/translation_conflicts.csv")
  cli::cli_alert_warning("{dplyr::n_distinct(conflicts$en_text)} term(s) have conflicting FR translations across tables - see data-raw/translation_conflicts.csv")
}

agreeing_terms <- term_agreement |> dplyr::filter(.data$n_distinct_fr == 1)
global_rows <- agreeing_terms |>
  dplyr::transmute(.data$en_text, .data$context, table_id = NA_character_, .data$fr_text)
scoped_rows <- pairs_expanded |>
  dplyr::semi_join(conflicting_terms, by = c("en_text", "context")) |>
  dplyr::distinct(.data$en_text, .data$context, .data$table_id, .data$fr_text)

auto <- dplyr::bind_rows(global_rows, scoped_rows) |>
  dplyr::arrange(.data$context, .data$en_text, .data$table_id)

# ---- preserve existing hand edits, matched by (en_text, context, table_id) -
long <- auto |>
  dplyr::transmute(
    en_text = .data$en_text, context = .data$context, table_id = .data$table_id,
    `FR text (auto)` = .data$fr_text, `FR text (custom)` = ""
  )

if (file.exists(OUT_PATH)) {
  previous <- read_excel(OUT_PATH, sheet = 1) |>
    # An all-NA table_id column (every term promoted to global) reads back
    # from Excel as logical rather than character - force it back to match
    # `long`'s type before the join below, or dplyr errors on the mismatch.
    dplyr::mutate(table_id = as.character(.data$table_id),
                   `FR text (custom)` = as.character(.data$`FR text (custom)`)) |>
    dplyr::filter(!is.na(.data$`FR text (custom)`), nzchar(trimws(.data$`FR text (custom)`))) |>
    dplyr::distinct(.data$en_text, .data$context, .data$table_id, .keep_all = TRUE) |>
    dplyr::rename(`FR text (custom) prev` = `FR text (custom)`) |>
    dplyr::select("en_text", "context", "table_id", "FR text (custom) prev")

  long <- long |>
    dplyr::left_join(previous, by = c("en_text", "context", "table_id")) |>
    dplyr::mutate(`FR text (custom)` = dplyr::coalesce(`FR text (custom) prev`, `FR text (custom)`)) |>
    dplyr::select(-"FR text (custom) prev")
}

wb <- createWorkbook()
addWorksheet(wb, "translation_overrides")
writeDataTable(wb, "translation_overrides", long, tableStyle = "TableStyleLight1")
setColWidths(wb, "translation_overrides", cols = seq_along(long), widths = "auto")
fs::dir_create("app/data")
saveWorkbook(wb, OUT_PATH, overwrite = TRUE)
cli::cli_alert_info("Wrote {nrow(long)} rows to {OUT_PATH}")

# ---- bake resolved values into category_translations -----------------------
resolved <- long |>
  dplyr::mutate(
    fr_text = ifelse(nzchar(trimws(.data$`FR text (custom)`)), .data$`FR text (custom)`, .data$`FR text (auto)`),
    source = ifelse(nzchar(trimws(.data$`FR text (custom)`)), "custom", "auto")
  ) |>
  dplyr::transmute(.data$en_text, .data$context, .data$table_id, .data$fr_text, .data$source)

con2 <- dbConnect(duckdb(), DB_PATH, read_only = FALSE)
dbWriteTable(con2, "category_translations", resolved, overwrite = TRUE)
dbDisconnect(con2, shutdown = TRUE)

cli::cli_alert_success("Baked {nrow(resolved)} rows into {DB_PATH}'s category_translations table")
