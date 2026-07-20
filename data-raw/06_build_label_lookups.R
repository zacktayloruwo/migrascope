# Builds/refreshes two editable lookup tables app.R reads at startup (see
# app/app.R's read_custom_name_lookup()):
#  - app/data/series_names.xlsx: table_id -> Series (custom) - overrides
#    derive_series_label()'s automatic guess for one specific table.
#  - app/data/breakdown_names.xlsx: Breakdown item (auto) -> (custom) -
#    overrides a normalized category name everywhere at once (the Break
#    down by choice list, Series/candidate matching, and the resolved
#    chart's category axis all key off the same overridden name - see
#    build_theme_dimension_map()'s breakdown_label_lookup param in
#    app/R/app_utils.R).
#
# Both are real Excel Tables (not just sheets of values) so they're easy
# to filter/sort/edit by hand. Regenerating is non-destructive: existing
# "(custom)" values are preserved (matched by table_id / Breakdown item
# (auto) respectively) so hand edits survive a re-run after new source
# tables are added; a table_id/breakdown item no longer in the catalog is
# dropped, a new one appears with a blank "(custom)" cell.
#
# Supersedes the old data-raw/06_build_short_labels.R (built
# app/data/table_short_labels.xlsx, an editable "Data table" dropdown
# label lookup) - that dropdown was removed when Geographic Aggregation/
# Break down by/Series replaced it, so the file and its generator were
# both dead weight and have been deleted/repurposed.

library(DBI)
library(duckdb)
library(dplyr)
library(openxlsx)
library(readxl)

# app_utils.R lives under app/ (it's app.R's own query/rendering helper
# file) rather than being duplicated here - this is the one data-prep
# script that needs a couple of its functions (build_theme_dimension_map(),
# split_temporary_workers()).
source("app/R/app_utils.R")

DB_PATH <- "app/data/immigration.duckdb"
SERIES_OUT_PATH <- "app/data/series_names.xlsx"
BREAKDOWN_OUT_PATH <- "app/data/breakdown_names.xlsx"

if (!file.exists(DB_PATH)) {
  stop("app/data/immigration.duckdb not found - run data-raw/05_build_duckdb.R first")
}

con <- dbConnect(duckdb(), DB_PATH, read_only = TRUE)
catalog <- tbl(con, "catalog") |> collect() |> split_temporary_workers()
dbDisconnect(con, shutdown = TRUE)

# No lookups passed in - these are the fresh, un-overridden "(auto)"
# values, regardless of whatever "(custom)" overrides are already active
# in the files being regenerated.
dim_map <- build_theme_dimension_map(catalog)

DATASET_LABELS <- c(
  permanent_residents    = "Permanent Residents",
  temporary_workers_imp  = "International Mobility Program",
  temporary_workers_tfwp = "Temporary Foreign Worker Program",
  study_permit_holders   = "Study Permit Holders",
  tr_to_pr_transition    = "TR → PR Transition",
  asylum_claimants       = "Asylum Claimants",
  refugees               = "Refugees"
)

# ---- series_names.xlsx ----------------------------------------------------
series_names <- data.frame(
  table_id = dim_map$table_id,
  Theme = unname(DATASET_LABELS[dim_map$dataset]),
  `Series (auto)` = dim_map$series_label,
  `Series (custom)` = "",
  check.names = FALSE, stringsAsFactors = FALSE
)

if (file.exists(SERIES_OUT_PATH)) {
  previous <- read_excel(SERIES_OUT_PATH, sheet = 1) |>
    select(table_id, `Series (custom)`) |>
    rename(`Series (custom) prev` = `Series (custom)`)

  series_names <- series_names |>
    left_join(previous, by = "table_id") |>
    mutate(`Series (custom)` = coalesce(`Series (custom) prev`, `Series (custom)`)) |>
    select(-`Series (custom) prev`)
}

series_names <- series_names |> arrange(Theme, `Series (auto)`)

wb <- createWorkbook()
addWorksheet(wb, "series_names")
writeDataTable(wb, "series_names", series_names, tableStyle = "TableStyleMedium2")
setColWidths(wb, "series_names", cols = 1:4, widths = c(60, 24, 42, 42))
freezePane(wb, "series_names", firstRow = TRUE)
saveWorkbook(wb, SERIES_OUT_PATH, overwrite = TRUE)
cat(sprintf("Wrote %d rows to %s\n", nrow(series_names), SERIES_OUT_PATH))

# ---- breakdown_names.xlsx -------------------------------------------------
breakdown_names <- data.frame(
  `Breakdown item (auto)` = sort(unique(unlist(dim_map$categories))),
  `Breakdown item (custom)` = "",
  check.names = FALSE, stringsAsFactors = FALSE
)

if (file.exists(BREAKDOWN_OUT_PATH)) {
  previous <- read_excel(BREAKDOWN_OUT_PATH, sheet = 1) |>
    select(`Breakdown item (auto)`, `Breakdown item (custom)`) |>
    rename(`Breakdown item (custom) prev` = `Breakdown item (custom)`)

  breakdown_names <- breakdown_names |>
    left_join(previous, by = "Breakdown item (auto)") |>
    mutate(`Breakdown item (custom)` = coalesce(`Breakdown item (custom) prev`, `Breakdown item (custom)`)) |>
    select(-`Breakdown item (custom) prev`)
}

wb2 <- createWorkbook()
addWorksheet(wb2, "breakdown_names")
writeDataTable(wb2, "breakdown_names", breakdown_names, tableStyle = "TableStyleMedium2")
setColWidths(wb2, "breakdown_names", cols = 1:2, widths = c(50, 50))
freezePane(wb2, "breakdown_names", firstRow = TRUE)
saveWorkbook(wb2, BREAKDOWN_OUT_PATH, overwrite = TRUE)
cat(sprintf("Wrote %d rows to %s\n", nrow(breakdown_names), BREAKDOWN_OUT_PATH))
