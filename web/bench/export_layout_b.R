# Phase 0 bench only (docs/wasm-port-plan.md, "Phase 0 timing comparison"):
# writes contender B's layout - one Parquet file per theme, sorted by
# geo_level first, with small (20k-row) row groups so DuckDB can skip the
# levels a query doesn't touch - into web/public/bench/. Contenders A and C
# read the production files from data-raw/10_export_web.R instead.
#
# Run from the project root after data-raw/10_export_web.R.

library(DBI)
library(duckdb)

OUT_DIR <- "web/public/bench"
unlink(OUT_DIR, recursive = TRUE)
dir.create(OUT_DIR, recursive = TRUE)

con <- dbConnect(duckdb(), "app/data/immigration.duckdb", read_only = TRUE)
invisible(dbExecute(con, "SET threads = 1"))
for (theme in dbGetQuery(con, "SELECT DISTINCT theme FROM series_facts")$theme) {
  invisible(dbExecute(con, sprintf("
    COPY (
      SELECT * EXCLUDE (theme) FROM series_facts WHERE theme = '%s'
      ORDER BY geo_level, series, facet, geo_1, geo_2, geo_3,
               breakdown_1, breakdown_2, breakdown_3, period_year, period_month
    ) TO '%s/theme=%s.parquet' (FORMAT parquet, COMPRESSION zstd, ROW_GROUP_SIZE 20000)",
    theme, OUT_DIR, theme)))
}
dbDisconnect(con, shutdown = TRUE)
message("Wrote contender B files to ", OUT_DIR)
