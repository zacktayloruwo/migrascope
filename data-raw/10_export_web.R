# Exports everything the static web app (web/) reads, from the same
# app/data/immigration.duckdb the Shiny app uses, into web/public/data/.
# See docs/wasm-port-plan.md ("Data export") for the design.
#
#  - series_facts/theme=<slug>/geo_level=<lvl>.<hash>.parquet: series_facts
#    split by theme x geographic level, sorted so zstd compresses it to
#    ~2.8 MB in total. The partition columns (theme, geo_level) are not
#    stored inside each file - the loader adds them back from manifest.json.
#  - series_summary.json: build_series_summary() - drives every selector, so
#    the UI can render before any Parquet is decoded.
#  - geo_units.json: list_series_geo_units() for every non-National
#    (theme, series, facet, geo_level) - Geographic unit picker choices,
#    display labels and ordering already resolved.
#  - landing.json / views/<theme>.default.json: pre-aggregated entry points
#    (landing cards, and the chart each theme opens on), computed with the
#    app's own build_series_plot_data() so they're correct by construction.
#  - translations.parquet + strings.json: category_translations, the
#    hand-maintained series/facet French labels, and the UI chrome strings.
#  - sources.json: build_source_lookup(), keyed by the 8-char table hash, for
#    citations.
#  - manifest.json: build date, data-through month, table count, and every
#    file above with its size and hash (hashed filenames let the browser cache
#    data files forever; a refresh is just a new manifest).
#
# Must run after 08_build_series_facts.R, 09_* if French coverage changed,
# and 09b_add_statcan_npr.R (which re-adds the Statistics Canada theme that
# 08 drops). Run from the project root.

library(DBI)
library(duckdb)
library(dplyr)

source("app/R/app_utils.R")
source("app/R/i18n.R")

DB_PATH <- "app/data/immigration.duckdb"
OUT_DIR <- "web/public/data"
DEFAULT_TOP_N <- 10

if (!file.exists(DB_PATH)) {
  stop("app/data/immigration.duckdb not found - run data-raw/05 through 08 first")
}

con <- dbConnect(duckdb(), DB_PATH, read_only = TRUE)
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)

if (file.exists("app/data/statcan_sources.csv") &&
    dbGetQuery(con, "SELECT count(*) AS n FROM series_facts WHERE theme = 'npr_population'")$n == 0) {
  stop("series_facts has no npr_population rows - run data-raw/09b_add_statcan_npr.R after 08/09")
}

unlink(OUT_DIR, recursive = TRUE)
dir.create(file.path(OUT_DIR, "views"), recursive = TRUE)

write_json <- function(x, name) {
  path <- file.path(OUT_DIR, name)
  jsonlite::write_json(x, path, auto_unbox = TRUE, null = "null", na = "null", digits = NA)
  invisible(path)
}

quiet_exec <- function(sql) invisible(dbExecute(con, sql))

short_hash <- function(path) substr(unname(tools::md5sum(path)), 1, 8)

# ---- series_facts, partitioned by theme x geo_level -------------------------
# Sort order matters twice over: it's what lets zstd's dictionary/RLE
# encodings collapse 4.5M rows to a few MB, and it keeps each view's rows
# contiguous for row-group skipping.
sf_dir <- file.path(OUT_DIR, "series_facts")
# Single-threaded, and ordered on every column (the last few only break
# ties, e.g. a year row and a month row), so a re-run over unchanged data
# writes byte-identical files - same hashes, so browsers keep their cached
# copies - however series_facts happens to be stored (09b appends to it).
quiet_exec("SET threads = 1")
quiet_exec(sprintf("
  COPY (
    SELECT * FROM series_facts
    ORDER BY theme, geo_level, series, facet, geo_1, geo_2, geo_3,
             breakdown_1, breakdown_2, breakdown_3, period_year, period_month,
             period_type, period_quarter, is_stock, source_table_id, value
  ) TO '%s' (FORMAT parquet, COMPRESSION zstd, PARTITION_BY (theme, geo_level),
             ROW_GROUP_SIZE 100000, OVERWRITE)", sf_dir))

part_rows <- dbGetQuery(con, "SELECT theme, geo_level, COUNT(*)::INTEGER AS rows FROM series_facts GROUP BY ALL")
parquet_files <- lapply(seq_len(nrow(part_rows)), function(i) {
  theme <- part_rows$theme[i]
  geo_level <- part_rows$geo_level[i]
  part_dir <- file.path(sf_dir, paste0("theme=", theme))
  src <- file.path(part_dir, paste0("geo_level=", geo_level), "data_0.parquet")
  stopifnot(file.exists(src))
  dest_name <- sprintf("geo_level=%s.%s.parquet", geo_level, short_hash(src))
  file.rename(src, file.path(part_dir, dest_name))
  unlink(file.path(part_dir, paste0("geo_level=", geo_level)), recursive = TRUE)
  list(theme = theme, geo_level = geo_level, rows = part_rows$rows[i],
       path = file.path("series_facts", paste0("theme=", theme), dest_name),
       bytes = file.size(file.path(part_dir, dest_name)))
})

# ---- selector metadata ------------------------------------------------------
series_summary <- build_series_summary(con)
# Monthly rows only at quarter ends (Statistics Canada's quarterly estimates,
# data-raw/09b): the explorer offers Quarterly and Annual, not Monthly.
quarterly_only <- dbGetQuery(con, "
  SELECT theme, series, facet, geo_level, bool_and(period_month IN (3, 6, 9, 12)) AS quarterly_only
  FROM series_facts WHERE period_type = 'month' GROUP BY ALL")
series_summary <- series_summary |>
  left_join(quarterly_only, by = c("theme", "series", "facet", "geo_level")) |>
  mutate(quarterly_only = coalesce(quarterly_only, FALSE))
write_json(series_summary, "series_summary.json")

geo_rows <- series_summary[series_summary$geo_level != "National", , drop = FALSE]
geo_units <- lapply(seq_len(nrow(geo_rows)), function(i) {
  r <- geo_rows[i, ]
  units <- list_series_geo_units(con, r$theme, r$series, r$facet, r$geo_level, r$geo_depth)
  list(theme = r$theme, series = r$series, facet = r$facet, geo_level = r$geo_level,
       values = unname(units), labels = names(units))
})
write_json(geo_units, "geo_units.json")

# ---- default view per theme (mirrors app.R's selection logic) ---------------
#' The Series a theme opens on - the same ranking app.R's input$theme
#' observer uses (most scope rows, deepest geography, has deeper breakdowns,
#' has monthly data, longest span, then alphabetical).
default_series_for <- function(theme_rows) {
  theme_rows |>
    group_by(series) |>
    summarise(
      n_scope = n(), max_geo_depth = max(geo_depth),
      any_breakdown = max(has_breakdown_2 | has_breakdown_3),
      any_month = max(has_month), year_span = max(max_year) - min(min_year),
      .groups = "drop"
    ) |>
    arrange(desc(n_scope), desc(max_geo_depth), desc(any_breakdown), desc(any_month),
            desc(year_span), series) |>
    pull(series) |>
    first()
}

#' The facet the explorer shows first at National level: "Total" when the
#' series publishes one (app.R's "none" choice), else the alphabetically
#' first real facet - same rule as the input$series observer.
default_facet_for <- function(series_rows) {
  national <- series_rows$facet[series_rows$geo_level == "National"]
  if ("Total" %in% national) "Total" else sort(setdiff(unique(national), "Total"))[1]
}

plot_rows <- function(d) {
  if (nrow(d) == 0) return(list())
  data.frame(category = as.character(d$category), period = as.character(d$period_display),
             period_sort = d$period_sort, value = d$value)
}

data_through <- dbGetQuery(con, "
  SELECT max(period_year * 100 + period_month) AS ym FROM series_facts WHERE period_type = 'month'")$ym

#' One National, Annual, absolute view of `series` at its default facet -
#' exactly what the explorer plots for those inputs (I() keeps length-1
#' vectors as JSON arrays).
build_view <- function(theme, series) {
  srows <- series_summary[series_summary$theme == theme & series_summary$series == series, , drop = FALSE]
  facet <- default_facet_for(srows)
  scope <- srows[srows$facet == facet & srows$geo_level == "National", , drop = FALSE][1, ]
  granularity <- "Annual"
  years <- c(scope$min_year, scope$max_year)
  d <- build_series_plot_data(con, theme, series, facet, "National", scope$geo_depth,
                               granularity, years, scope$is_stock, DEFAULT_TOP_N)
  list(
    theme = theme, series = series, facet = facet, geo_level = "National",
    geo_depth = scope$geo_depth, granularity = granularity, years = years,
    is_stock = scope$is_stock, has_month = scope$has_month, top_n = DEFAULT_TOP_N,
    display_as = "absolute",
    category_order = I(levels(d$category)),
    period_order = I(levels(d$period_display)),
    rows = plot_rows(d),
    source_table_ids = I(series_source_table_ids(con, theme, series, facet, "National"))
  )
}

default_views <- list()
for (theme in unique(series_summary$theme)) {
  view <- build_view(theme, default_series_for(series_summary[series_summary$theme == theme, , drop = FALSE]))
  invisible(write_json(view, sprintf("views/%s.default.json", theme)))
  default_views[[theme]] <- view
}

# The explorer's default series isn't always the best headline for a landing
# card (e.g. refugees' default series stops in 2021, and study permits'
# default is a December-31 stock) - these themes headline a different series.
LANDING_SERIES <- c(
  study_permit_holders = "All permits (Year became effective)",
  tr_to_pr_transition  = "Prior study permit",
  refugees             = "Outcome"
)

# ---- landing cards ----------------------------------------------------------
#' Annual totals for a view, summing every plotted category (including the
#' Suppressed Residual, which completes the published total).
annual_totals <- function(view) {
  rows <- as.data.frame(view$rows)
  rows |> group_by(period, period_sort) |> summarise(value = sum(value), .groups = "drop") |>
    arrange(period_sort)
}

landing <- lapply(default_views, function(view) {
  if (view$theme %in% names(LANDING_SERIES)) view <- build_view(view$theme, LANDING_SERIES[[view$theme]])
  totals <- annual_totals(view)
  # A series whose last year is the current data year is partial unless the
  # data runs through December - including IRB's annual-only tables, which
  # are republished quarterly with a cumulative, year-to-date current year.
  latest <- max(totals$period_sort)
  complete_year <- if (latest == data_through %/% 100 && data_through %% 100 < 12) {
    latest - 1
  } else {
    latest
  }
  spark <- totals[totals$period_sort >= 2015 & totals$period_sort <= complete_year, , drop = FALSE]
  cur <- totals$value[totals$period_sort == complete_year]
  prev <- totals$value[totals$period_sort == complete_year - 1]
  list(
    theme = view$theme, series = view$series, facet = view$facet,
    is_stock = view$is_stock,
    complete_year = complete_year, value = cur,
    previous_value = if (length(prev)) prev else NULL,
    change_pct = if (length(prev) && prev > 0) round(100 * (cur / prev - 1), 1) else NULL,
    spark_years = I(spark$period_sort), spark_values = I(spark$value)
  )
})
write_json(unname(landing), "landing.json")

# ---- translations, chrome strings, citations --------------------------------
if (has_category_translations(con)) {
  quiet_exec(sprintf("COPY (SELECT en_text, context, table_id, fr_text FROM category_translations
                           ORDER BY context, en_text) TO '%s' (FORMAT parquet, COMPRESSION zstd)",
                         file.path(OUT_DIR, "translations.parquet")))
}
write_json(list(
  strings = lapply(STRINGS, function(s) list(en = unname(s[["en"]]), fr = unname(s[["fr"]]))),
  series_facet_fr = as.list(SERIES_FACET_LABELS_FR)
), "strings.json")

# About pages, rendered the way app.R renders them (shiny::markdown() is
# commonmark with GitHub extensions), with the live table count filled in.
# Statistics Canada tables (data-raw/09b_add_statcan_npr.R) aren't in catalog.
statcan_sources <- if (file.exists("app/data/statcan_sources.csv")) {
  readr::read_csv("app/data/statcan_sources.csv", show_col_types = FALSE, col_types = readr::cols(.default = "c"))
} else NULL
n_tables <- dbGetQuery(con, "SELECT COUNT(*)::INTEGER AS n FROM catalog")$n + NROW(statcan_sources)
for (lang in c("en", "fr")) {
  src <- if (lang == "en") "app/ABOUT.md" else "app/ABOUT_fr.md"
  md <- gsub("{{N_TABLES}}", n_tables, paste(readLines(src, warn = FALSE), collapse = "\n"), fixed = TRUE)
  writeLines(commonmark::markdown_html(md, extensions = TRUE), file.path(OUT_DIR, sprintf("about_%s.html", lang)))
}

manifest_csv <- readr::read_csv("app/data/source_manifest.csv", show_col_types = FALSE,
                                col_types = readr::cols(last_modified_ckan = "c"))
# `portal` picks the citation wording: Open Government Portal (IRCC/IRB) or Statistics Canada.
sources <- bind_rows(
  build_source_lookup(manifest_csv) |> mutate(portal = "open_canada"),
  if (!is.null(statcan_sources)) statcan_sources |>
    transmute(hash, agency, table_name, format, url, dataset_url, updated_at, portal = "statcan",
              agency_fr, table_name_fr, dataset_url_fr)
)
write_json(sources, "sources.json")

# ---- when the source data was last pulled ----------------------------------
# 02_download_data.R stamps each run in download_log.csv (checked_at); logs
# from before that column existed fall back to the log file's own mtime,
# which is when that run wrote it.
download_log <- readr::read_csv("data-raw/download_log.csv", show_col_types = FALSE,
                                col_types = readr::cols(.default = "c"))
data_pulled <- if ("checked_at" %in% names(download_log) && any(!is.na(download_log$checked_at))) {
  substr(max(download_log$checked_at, na.rm = TRUE), 1, 10)
} else {
  format(file.mtime("data-raw/download_log.csv"), "%Y-%m-%d")
}

# ---- manifest ---------------------------------------------------------------
json_files <- c("series_summary.json", "geo_units.json", "landing.json", "strings.json",
                "sources.json", "about_en.html", "about_fr.html", sprintf("views/%s.default.json", names(default_views)),
                if (file.exists(file.path(OUT_DIR, "translations.parquet"))) "translations.parquet")
write_json(list(
  built_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z"),
  data_through = sprintf("%d-%02d", data_through %/% 100, data_through %% 100),
  data_pulled = data_pulled,
  n_tables = n_tables,
  series_facts = parquet_files,
  files = lapply(json_files, function(f) list(path = f, bytes = file.size(file.path(OUT_DIR, f)),
                                              hash = short_hash(file.path(OUT_DIR, f))))
), "manifest.json")

total_kb <- round(sum(vapply(parquet_files, `[[`, numeric(1), "bytes")) / 1024)
message(sprintf("Exported %d Parquet files (%d KB) + %d JSON/aux files to %s",
                length(parquet_files), total_kb, length(json_files), OUT_DIR))
