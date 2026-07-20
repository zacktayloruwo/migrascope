# Builds reports/series_reference.xlsx: a read-only reference table of
# every Series the app can show, one row per (Series x Geographic
# Aggregation level x Temporal Aggregation level) combination - Theme,
# Series, its available Breakdown items, that row's Geographic
# Aggregation level, that row's Temporal Aggregation level, and the full
# source table title exactly as it appears in the app's own citation (not
# catalog$table_title, which can carry an internal multi-sheet suffix the
# citation doesn't show).
#
# Reflects the SAME series_names.xlsx/breakdown_names.xlsx "(custom)"
# overrides the live app applies (see app.R and
# app/R/app_utils.R::read_custom_name_lookup()) - this is a snapshot of
# what a user actually sees, not the raw auto-derived defaults (that's
# what data-raw/06_build_label_lookups.R's own "(auto)" columns are for).
#
# Not consumed by the app itself - a standalone report for humans, safe to
# regenerate any time after 05_build_duckdb.R/06_build_label_lookups.R.

library(DBI)
library(duckdb)
library(dplyr)
library(openxlsx)
library(readxl)

# app_utils.R lives under app/ (it's app.R's own query/rendering helper
# file) rather than being duplicated here.
source("app/R/app_utils.R")

DB_PATH <- "app/data/immigration.duckdb"
OUT_PATH <- "reports/series_reference.xlsx"

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
GEO_RANK_LABELS <- c(PT = "Province/Territory", CMA = "CMA", CD = "CD", CSD = "CSD")

con <- dbConnect(duckdb(), DB_PATH, read_only = TRUE)
catalog <- tbl(con, "catalog") |> collect() |> split_temporary_workers()
dbDisconnect(con, shutdown = TRUE)

series_label_lookup <- read_custom_name_lookup("app/data/series_names.xlsx", "table_id", "Series (custom)")
breakdown_label_lookup <- read_custom_name_lookup("app/data/breakdown_names.xlsx", "Breakdown item (auto)",
                                                   "Breakdown item (custom)")
dim_map <- build_theme_dimension_map(catalog, series_label_lookup = series_label_lookup,
                                      breakdown_label_lookup = breakdown_label_lookup)

# ---- full citation title, same source app.R's table_citation_ui() uses --
# catalog$table_title is title_for_slug()'s pipeline-internal title (e.g.
# a multi-sheet table gets " — Sheet Name" appended) - not necessarily
# what the app actually cites at the bottom of the plot card, which is
# built from app/data/source_manifest.csv's own table_name field via
# build_source_lookup(). For synthetic/derived tables (no hash match, e.g.
# the merged refugees table) the app falls back to citing every sibling
# source table within the same theme - replicated here.
manifest <- readr::read_csv("app/data/source_manifest.csv", show_col_types = FALSE,
                             col_types = readr::cols(last_modified_ckan = "c"))
source_lookup <- build_source_lookup(manifest)

citation_title_for <- function(table_id, sibling_ids) {
  hash <- extract_table_hash(table_id)
  hashes <- if (!is.na(hash)) {
    hash
  } else {
    sibling_hashes <- vapply(sibling_ids, extract_table_hash, character(1))
    unique(sibling_hashes[!is.na(sibling_hashes)])
  }
  rows <- source_lookup[source_lookup$hash %in% hashes, , drop = FALSE]
  if (nrow(rows) == 0) return(NA_character_)
  paste(unique(rows$table_name), collapse = "; ")
}

citation_title <- vapply(seq_len(nrow(dim_map)), function(i) {
  sibling_ids <- catalog$table_id[catalog$dataset == dim_map$dataset[i]]
  citation_title_for(dim_map$table_id[i], sibling_ids)
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
