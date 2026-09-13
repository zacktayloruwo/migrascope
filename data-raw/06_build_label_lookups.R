# Builds/refreshes app/data/label_overrides.xlsx, a single hand-editable
# lookup covering both a table's overall Series name and each of its
# Breakdown items - long format, one row per table_id plus one additional
# row per non-geographic/non-filler breakdown level that table has (a table
# with no breakdown levels gets exactly one row, breakdown columns blank,
# so its Series edit still has somewhere to live). `Breakdown item (custom)`
# is keyed by (table_id, Breakdown item (auto)) - not by the raw label
# alone - so the same raw label (e.g. "Immigration Category") can be
# corrected differently in different tables instead of one global rename;
# see derive_theme_dimension_map()'s breakdown_label_lookup application and
# read_custom_name_lookup()'s `key_col2`/BREAKDOWN_KEY_SEP in
# app/R/app_utils.R. `Source table title` is read-only/for-reference-only
# (never written back) - the full citation title (see
# app_utils.R::citation_title_for()), included because `table_id` alone is
# an opaque hash-prefixed slug and an editor needs to know which real
# source table they're looking at.
#
# Unlike the old per-app-startup version of this file (data/series_names.xlsx
# + data/breakdown_names.xlsx, read live by app.R), this script now ALSO
# bakes the resolved (custom-if-present-else-auto) values straight into
# app/data/immigration.duckdb's `catalog` table: a new `series_label` column,
# and the relevant `level_N_label` cell(s) rewritten per table. app.R and
# data-raw/07_build_series_reference.R then just read `catalog` directly -
# neither touches label_overrides.xlsx or any lookup logic at runtime.
#
# Regenerating is non-destructive: existing "(custom)" values are preserved
# (matched by table_id / (table_id, Breakdown item (auto)) respectively) so
# hand edits survive a re-run after new source tables are added; a
# table_id/breakdown item no longer in the catalog is dropped, a new one
# appears with a blank "(custom)" cell.
#
# IMPORTANT: must run after data-raw/05_build_duckdb.R, not on its own -
# the "auto" columns are always derived fresh from catalog's raw,
# uncurated level_N_label/table_title (see derive_theme_dimension_map()).
# 05 always rewrites `catalog` from scratch, so 05 -> 06 gives a true raw
# baseline every time; running 06 twice in a row without an intervening 05
# just re-derives "auto" from whatever this script itself wrote last time,
# which is harmless (already-resolved text re-normalizes to itself) but not
# the original uncurated baseline.

library(DBI)
library(duckdb)
library(dplyr)
library(openxlsx)
library(readxl)

# app_utils.R lives under app/ (it's app.R's own query/rendering helper
# file) rather than being duplicated here - this is the one data-prep
# script that needs several of its functions (derive_theme_dimension_map(),
# split_temporary_workers(), citation_title_for(), build_source_lookup(),
# read_custom_name_lookup()).
source("app/R/app_utils.R")

DB_PATH <- "app/data/immigration.duckdb"
OUT_PATH <- "app/data/label_overrides.xlsx"

if (!file.exists(DB_PATH)) {
  stop("app/data/immigration.duckdb not found - run data-raw/05_build_duckdb.R first")
}

DATASET_LABELS <- c(
  permanent_residents    = "Permanent Residents",
  temporary_workers_imp  = "International Mobility Program",
  temporary_workers_tfwp = "Temporary Foreign Worker Program",
  study_permit_holders   = "Study Permit Holders",
  tr_to_pr_transition    = "TR → PR Transition",
  asylum_claimants       = "Asylum Claimants",
  refugees               = "Refugees"
)

con <- dbConnect(duckdb(), DB_PATH, read_only = TRUE)
catalog <- tbl(con, "catalog") |> collect() |> split_temporary_workers()
# con stays open through the breakdown-row generation below (really_filler_levels()
# needs it to content-check generic-fallback labels against `facts`) - disconnected
# after that loop, near the bottom of this section.

# No lookups passed in - these are the fresh, un-overridden "(auto)"
# values, regardless of whatever "(custom)" overrides are already active
# in label_overrides.xlsx or baked into `catalog` from a previous run.
dim_map <- derive_theme_dimension_map(catalog)

manifest <- readr::read_csv("app/data/source_manifest.csv", show_col_types = FALSE,
                             col_types = readr::cols(last_modified_ckan = "c"))
source_lookup <- build_source_lookup(manifest)

citation_title <- vapply(seq_len(nrow(dim_map)), function(i) {
  sibling_ids <- catalog$table_id[catalog$dataset == dim_map$dataset[i]]
  citation_title_for(dim_map$table_id[i], sibling_ids, source_lookup)
}, character(1))

# ---- long-format table: table_id + Theme + Series repeated across one row
# per breakdown level (or one blank-breakdown row if the table has none) --
long <- lapply(seq_len(nrow(dim_map)), function(i) {
  cl <- dim_map$classification[[i]]
  # Same content-aware filler check as 08_build_series_facts.R's
  # table_shape() (see really_filler_levels()'s own comment) - without
  # this, a generic-fallback level that 08 content-overrides into a real,
  # mergeable facet would never get an editable row here, leaving no way to
  # give two tables' same real-world dimension a matching label (the actual
  # bug this fixed: temporary_workers/520ac8e1's "Program Level 2" and
  # temporary_workers/d5779439's "Program" are the same breakdown, but 08's
  # exact-string facet grouping only recognizes that once both resolve to
  # the same label text).
  really_filler <- really_filler_levels(cl, con, dim_map$table_id[i])
  breakdown_rows <- cl[is.na(cl$geo_rank) & !really_filler, , drop = FALSE]

  if (nrow(breakdown_rows) == 0) {
    data.frame(
      table_id = dim_map$table_id[i], Theme = unname(DATASET_LABELS[dim_map$dataset[i]]),
      `Series (auto)` = dim_map$series_label[i], `Breakdown item (auto)` = NA_character_,
      `Source table title` = citation_title[i], level_index = NA_integer_,
      check.names = FALSE, stringsAsFactors = FALSE
    )
  } else {
    data.frame(
      table_id = dim_map$table_id[i], Theme = unname(DATASET_LABELS[dim_map$dataset[i]]),
      `Series (auto)` = dim_map$series_label[i], `Breakdown item (auto)` = breakdown_rows$label_normalized,
      `Source table title` = citation_title[i], level_index = breakdown_rows$level_index,
      check.names = FALSE, stringsAsFactors = FALSE
    )
  }
}) |> bind_rows()
dbDisconnect(con, shutdown = TRUE)

# A table whose own level labels aren't distinct after normalization (e.g.
# a mislabeled table where two/three levels all read literally "Immigration
# Category") would otherwise produce multiple rows sharing the exact same
# (table_id, Breakdown item (auto)) key - collapse those into one editable
# row per distinct label, keeping every underlying level_index so a
# "Breakdown item (custom)" override still gets applied to all of them
# below. Without this, repeated regeneration compounds: each run's
# preserve-edits join multiplies against the last run's now-duplicated
# rows (a many-to-many join, which is a bug signal, not a feature).
long <- long |>
  group_by(table_id, Theme, `Series (auto)`, `Breakdown item (auto)`, `Source table title`) |>
  summarise(level_index = list(level_index), .groups = "drop")

long$`Series (custom)` <- ""
long$`Breakdown item (custom)` <- ""

# ---- preserve existing hand edits, matched by stable keys ------------------
KNOWN_COLS <- c("table_id", "Theme", "Series (auto)", "Series (custom)",
                "Breakdown item (auto)", "Breakdown item (custom)", "Source table title")
extra_cols <- character(0)

if (file.exists(OUT_PATH)) {
  previous <- read_excel(OUT_PATH, sheet = 1)

  prev_series <- previous |>
    select(table_id, `Series (custom)`) |>
    filter(!is.na(`Series (custom)`) & nzchar(trimws(`Series (custom)`))) |>
    distinct(table_id, .keep_all = TRUE) |>
    rename(`Series (custom) prev` = `Series (custom)`)

  prev_breakdown <- previous |>
    select(table_id, `Breakdown item (auto)`, `Breakdown item (custom)`) |>
    filter(!is.na(`Breakdown item (custom)`) & nzchar(trimws(`Breakdown item (custom)`))) |>
    # self-heals a previous run's accumulated (table_id, Breakdown item
    # (auto)) duplicates (see the collapse step above) rather than letting
    # a stale duplicate multiply forever via this join
    distinct(table_id, `Breakdown item (auto)`, .keep_all = TRUE) |>
    rename(`Breakdown item (custom) prev` = `Breakdown item (custom)`)

  long <- long |>
    left_join(prev_series, by = "table_id") |>
    mutate(`Series (custom)` = coalesce(`Series (custom) prev`, `Series (custom)`)) |>
    select(-`Series (custom) prev`) |>
    left_join(prev_breakdown, by = c("table_id", "Breakdown item (auto)")) |>
    mutate(`Breakdown item (custom)` = coalesce(`Breakdown item (custom) prev`, `Breakdown item (custom)`)) |>
    select(-`Breakdown item (custom) prev`)

  # Any other hand-added column (e.g. a "Duplicate" flag column used to mark
  # candidates for review) isn't part of the schema this script manages, but
  # is carried forward as-is - matched by the same (table_id, Breakdown item
  # (auto)) key as Breakdown item (custom), since that's this file's finest
  # granularity - so an editor's freeform notes survive a regen exactly like
  # the "(custom)" columns do.
  extra_cols <- setdiff(names(previous), KNOWN_COLS)
  if (length(extra_cols) > 0) {
    prev_extra <- previous |>
      select(table_id, `Breakdown item (auto)`, dplyr::all_of(extra_cols)) |>
      distinct(table_id, `Breakdown item (auto)`, .keep_all = TRUE)
    long <- long |> left_join(prev_extra, by = c("table_id", "Breakdown item (auto)"))
  }
}

long <- long |>
  arrange(Theme, `Series (auto)`, table_id,
          vapply(level_index, function(x) if (all(is.na(x))) Inf else min(x, na.rm = TRUE), numeric(1)))

# ---- resolve final (custom-if-present-else-auto) values ---------------------
resolved_series <- long |>
  distinct(table_id, .keep_all = TRUE) |>
  mutate(resolved = ifelse(nzchar(trimws(`Series (custom)`)), `Series (custom)`, `Series (auto)`)) |>
  select(table_id, resolved) |>
  tibble::deframe()

breakdown_rows <- long |>
  filter(!vapply(level_index, function(x) all(is.na(x)), logical(1))) |>
  mutate(resolved = ifelse(nzchar(trimws(`Breakdown item (custom)`)), `Breakdown item (custom)`, `Breakdown item (auto)`))

# ---- bake resolved values into `catalog` ------------------------------------
# series_label is intentionally NOT forced unique per theme here - several
# tables legitimately sharing one series_label (whether auto-derived or a
# hand-typed "Series (custom)" value repeated on purpose) is the expected
# shape for "same series, different breakdown shape"; app/R/app_utils.R's
# match_candidates() is what keeps them from surfacing as separate,
# confusingly-identical Series options (see the note above that function).
catalog$series_label <- unname(resolved_series[catalog$table_id])
for (j in seq_len(nrow(breakdown_rows))) {
  ridx <- match(breakdown_rows$table_id[j], catalog$table_id)
  # usually one level_index per row - a table whose own levels weren't
  # distinct after normalization (see the collapse step above) can map one
  # editable row to several, all getting the same resolved value
  for (li in breakdown_rows$level_index[[j]]) {
    col <- paste0("level_", li, "_label")
    catalog[[col]][ridx] <- breakdown_rows$resolved[j]
  }
}

con2 <- dbConnect(duckdb(), DB_PATH, read_only = FALSE)
dbWriteTable(con2, "catalog", catalog, overwrite = TRUE)
dbDisconnect(con2, shutdown = TRUE)
cat(sprintf("Baked series_label + breakdown label overrides into %s's catalog table (%d rows)\n",
            DB_PATH, nrow(catalog)))

# ---- write label_overrides.xlsx (read-only Source table title included) ----
out <- long |> select(dplyr::all_of(KNOWN_COLS), dplyr::any_of(extra_cols))
out[is.na(out)] <- ""

n_cols <- ncol(out)
wb <- createWorkbook()
addWorksheet(wb, "label_overrides")
writeDataTable(wb, "label_overrides", out, tableStyle = "TableStyleMedium2")
setColWidths(wb, "label_overrides", cols = seq_len(n_cols),
             widths = c(60, 24, 42, 42, 34, 34, 90, rep(20, length(extra_cols))))
freezePane(wb, "label_overrides", firstRow = TRUE)
saveWorkbook(wb, OUT_PATH, overwrite = TRUE)
cat(sprintf("Wrote %d rows to %s\n", nrow(out), OUT_PATH))
