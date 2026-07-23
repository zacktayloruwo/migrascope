# Builds reports/series_reference.xlsx: a read-only reference table of
# every Series the app can show, one row per (Series x Geographic
# Aggregation level x Temporal Aggregation level) combination - Theme,
# Series, its available Breakdown items, that row's Geographic
# Aggregation level, that row's Temporal Aggregation level, and the full
# source table title exactly as it appears in the app's own citation (not
# catalog$table_title, which can carry an internal multi-sheet suffix the
# citation doesn't show).
#
# Reads `catalog` directly - by the time 05_build_duckdb.R and
# 06_build_label_lookups.R have both run, `catalog$level_N_label`/
# `catalog$series_label` already reflect every hand-typed correction in
# app/data/label_overrides.xlsx (baked in at database-creation time - see
# that script and app/R/app_utils.R::build_theme_dimension_map()), so this
# is a snapshot of what a user actually sees, not the raw auto-derived
# defaults.
#
# Not consumed by the app itself - a standalone report for humans, safe to
# regenerate any time after 05_build_duckdb.R/06_build_label_lookups.R.

library(DBI)
library(duckdb)
library(dplyr)
library(openxlsx)

# app_utils.R lives under app/ (it's app.R's own query/rendering helper
# file) rather than being duplicated here.
source("app/R/app_utils.R")

DB_PATH <- "app/data/immigration.duckdb"
OUT_PATH <- "reports/series_reference.xlsx"

if (!file.exists(DB_PATH)) {
  stop("app/data/immigration.duckdb not found - run data-raw/05_build_duckdb.R then data-raw/06_build_label_lookups.R first")
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
GEO_RANK_LABELS <- c(PT = "Province/Territory", CMA = "CMA", CD = "CD", CSD = "CSD")

con <- dbConnect(duckdb(), DB_PATH, read_only = TRUE)
catalog <- tbl(con, "catalog") |> collect() |> split_temporary_workers()
dbDisconnect(con, shutdown = TRUE)

dim_map <- build_theme_dimension_map(catalog)

# ---- full citation title, same source app.R's table_citation_ui() uses --
# catalog$table_title is title_for_slug()'s pipeline-internal title (e.g.
# a multi-sheet table gets " — Sheet Name" appended) - not necessarily
# what the app actually cites at the bottom of the plot card, which is
# built from app/data/source_manifest.csv's own table_name field via
# build_source_lookup(). For synthetic/derived tables (no hash match, e.g.
# the merged refugees table) the app falls back to citing every sibling
# source table within the same theme - see citation_title_for() in
# app/R/app_utils.R.
manifest <- readr::read_csv("app/data/source_manifest.csv", show_col_types = FALSE,
                             col_types = readr::cols(last_modified_ckan = "c"))
source_lookup <- build_source_lookup(manifest)

citation_title <- vapply(seq_len(nrow(dim_map)), function(i) {
  sibling_ids <- catalog$table_id[catalog$dataset == dim_map$dataset[i]]
  citation_title_for(dim_map$table_id[i], sibling_ids, source_lookup)
}, character(1))

breakdown_col <- vapply(dim_map$categories, function(x) {
  if (length(x) == 0) "" else paste(sort(x), collapse = ", ")
}, character(1))

rows <- lapply(seq_len(nrow(dim_map)), function(i) {
  geo_levels <- c("National", unname(GEO_RANK_LABELS[dim_map$geo_ranks[[i]]]))
  temporal_levels <- if (isTRUE(dim_map$has_month[i])) c("Monthly", "Quarterly", "Annual") else "Annual"

  expand.grid(
    Theme = unname(DATASET_LABELS[dim_map$dataset[i]]),
    Series = dim_map$series_label[i],
    `Breakdown items` = breakdown_col[i],
    `Geographic Aggregation` = geo_levels,
    `Temporal Aggregation` = temporal_levels,
    `Source table title` = citation_title[i],
    stringsAsFactors = FALSE,
    KEEP.OUT.ATTRS = FALSE
  )
})
reference <- do.call(rbind, rows)
reference <- reference[, c("Theme", "Series", "Breakdown items", "Geographic Aggregation",
                            "Temporal Aggregation", "Source table title")]
reference <- reference[order(reference$Theme, reference$Series, reference$`Source table title`,
                              reference$`Geographic Aggregation`, reference$`Temporal Aggregation`), ]
rownames(reference) <- NULL

fs::dir_create("reports")
wb <- createWorkbook()
addWorksheet(wb, "series_reference")
writeDataTable(wb, "series_reference", reference, tableStyle = "TableStyleMedium2")
setColWidths(wb, "series_reference", cols = 1:6, widths = c(24, 42, 40, 22, 18, 90))
freezePane(wb, "series_reference", firstRow = TRUE)
saveWorkbook(wb, OUT_PATH, overwrite = TRUE)

cat(sprintf("Wrote %d rows to %s\n", nrow(reference), OUT_PATH))
