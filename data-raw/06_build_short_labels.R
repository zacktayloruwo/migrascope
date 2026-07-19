# Builds/refreshes app/data/table_short_labels.xlsx: an editable lookup of
# "Data table" dropdown labels (see app/app.R,
# app/R/app_utils.R::simplify_table_label()). Writes straight into app/data/
# - that directory is the self-contained Shiny app bundle deployed to
# shinyapps.io - rather than a top-level data/ that would need copying over.
#
# The file is a real Excel Table (not just a sheet of values) so it's easy
# to filter/sort/edit by hand. Regenerating is non-destructive: existing
# short_label values are preserved for any table_id still in the catalog,
# so hand edits survive a re-run after new source tables are added. New
# table_ids get a computed default (from simplify_table_label()); table_ids
# no longer in the catalog are dropped.

library(DBI)
library(duckdb)
library(dplyr)
library(openxlsx)

# app_utils.R lives under app/ (it's app.R's own query/rendering helper
# file) rather than being duplicated here - this is the one data-prep
# script that needs a couple of its functions (simplify_table_label(),
# split_temporary_workers()).
source("app/R/app_utils.R")

DB_PATH <- "app/data/immigration.duckdb"
OUT_PATH <- "app/data/table_short_labels.xlsx"

if (!file.exists(DB_PATH)) {
  stop("app/data/immigration.duckdb not found - run data-raw/05_build_duckdb.R first")
}

con <- dbConnect(duckdb(), DB_PATH, read_only = TRUE)
catalog <- tbl(con, "catalog") |> collect() |> split_temporary_workers()
dbDisconnect(con, shutdown = TRUE)

current <- catalog |>
  transmute(
    dataset, table_id, table_title,
    short_label = mapply(simplify_table_label, table_title, dataset, USE.NAMES = FALSE)
  )

if (file.exists(OUT_PATH)) {
  previous <- read.xlsx(OUT_PATH, sheet = 1) |>
    select(table_id, short_label) |>
    rename(short_label_prev = short_label)

  current <- current |>
    left_join(previous, by = "table_id") |>
    mutate(short_label = coalesce(short_label_prev, short_label)) |>
    select(-short_label_prev)
}

current <- current |> arrange(dataset, table_title)

wb <- createWorkbook()
addWorksheet(wb, "short_labels")
writeDataTable(wb, "short_labels", current, tableStyle = "TableStyleMedium2")
setColWidths(wb, "short_labels", cols = 1:4, widths = c(24, 40, 70, 45))
saveWorkbook(wb, OUT_PATH, overwrite = TRUE)

cat(sprintf("Wrote %d rows to %s\n", nrow(current), OUT_PATH))
