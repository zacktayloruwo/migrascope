# Golden files for the web app's TypeScript query layer (docs/wasm-port-plan.md,
# "Proving parity"). Runs the Shiny app's own build_series_plot_data() and
# list_series_breakdown_values() over a stratified set of view configurations
# and writes the inputs + outputs to web/tests/golden/, one JSON file per
# theme. web/tests/parity.test.ts runs the TypeScript port over the exact
# same inputs, against the Parquet files from 10_export_web.R, and asserts the
# results match.
#
# Coverage: every (theme, series, facet, geo_level) in series_summary, at
# every granularity it supports; non-National levels both as "All" places and
# narrowed to one place; every drill depth that exists (first value at each
# level); plus percentage, small top-N and narrowed-year-range variants on a
# deterministic subset. Regenerate after every data refresh (after 10_*).
#
# Run from the project root.

library(DBI)
library(duckdb)
library(dplyr)

source("app/R/app_utils.R")

DB_PATH <- "app/data/immigration.duckdb"
OUT_DIR <- "web/tests/golden"

con <- dbConnect(duckdb(), DB_PATH, read_only = TRUE)
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)

unlink(OUT_DIR, recursive = TRUE)
dir.create(OUT_DIR, recursive = TRUE)

series_summary <- build_series_summary(con)

#' One case: the explorer's inputs, exactly as app.R passes them to
#' build_series_plot_data().
make_case <- function(r, granularity, years, top_n = 10, display_as = "absolute",
                      geo_unit_prefix = character(0), drill_1 = NULL, drill_2 = NULL) {
  list(theme = r$theme, series = r$series, facet = r$facet, geo_level = r$geo_level,
       geo_depth = r$geo_depth, granularity = granularity, years = as.integer(years),
       is_stock = r$is_stock, top_n = top_n, display_as = display_as,
       geo_unit_prefix = I(geo_unit_prefix), drill_1 = drill_1, drill_2 = drill_2)
}

cases <- list()
add <- function(case) cases[[length(cases) + 1]] <<- case

for (i in seq_len(nrow(series_summary))) {
  r <- series_summary[i, ]
  grans <- if (isTRUE(r$has_month)) c("Annual", "Quarterly", "Monthly") else "Annual"
  full <- c(r$min_year, r$max_year)

  # Which geography scopes this row supports, mirroring app.R: National
  # always; elsewhere, "All" places only for facet Total (app.R forces Total
  # when no unit is picked), plus one specific place for any facet.
  prefixes <- list()
  if (r$geo_level == "National") {
    prefixes <- list(character(0))
  } else {
    if (r$facet == "Total") prefixes <- list(character(0))
    units <- list_series_geo_units(con, r$theme, r$series, r$facet, r$geo_level, r$geo_depth)
    if (length(units) > 1) prefixes <- c(prefixes, list(parse_geo_unit(units[[2]])))
  }

  for (prefix in prefixes) {
    for (g in grans) add(make_case(r, g, full, geo_unit_prefix = prefix))

    # Deterministic variants on a subset, spread across themes.
    if (i %% 3 == 0) add(make_case(r, "Annual", full, display_as = "percent", geo_unit_prefix = prefix))
    if (i %% 5 == 0) add(make_case(r, grans[length(grans)], full, top_n = 3, geo_unit_prefix = prefix))
    if (i %% 4 == 0 && full[2] - full[1] >= 4) {
      add(make_case(r, grans[1], c(full[1] + 2, full[2] - 1), geo_unit_prefix = prefix))
    }

    # Drills: first value at each depth that exists for this facet.
    if (r$facet != "Total" && isTRUE(r$has_breakdown_2)) {
      d1 <- list_series_breakdown_values(con, r$theme, r$series, r$facet, r$geo_level)
      if (length(d1) > 0) {
        add(make_case(r, "Annual", full, geo_unit_prefix = prefix, drill_1 = d1[1]))
        if (isTRUE(r$has_breakdown_3)) {
          d2 <- list_series_breakdown_values(con, r$theme, r$series, r$facet, r$geo_level, d1[1])
          if (length(d2) > 0) {
            add(make_case(r, "Annual", full, geo_unit_prefix = prefix, drill_1 = d1[1], drill_2 = d2[1]))
          }
        }
      }
    }
  }
}

#' Run one case through the R implementation and attach its output.
run_case <- function(case) {
  d <- build_series_plot_data(
    con, theme = case$theme, series = case$series, facet = case$facet,
    geo_level = case$geo_level, geo_depth = case$geo_depth, granularity = case$granularity,
    year_range = case$years, is_stock = case$is_stock, top_n = case$top_n,
    display_as = case$display_as, geo_unit_prefix = as.character(case$geo_unit_prefix),
    drill_1 = case$drill_1, drill_2 = case$drill_2
  )
  case$expected <- if (nrow(d) == 0) {
    list(category_order = I(character(0)), period_order = I(character(0)), rows = I(list()))
  } else {
    list(
      category_order = I(levels(d$category)),
      period_order = I(levels(d$period_display)),
      rows = data.frame(category = as.character(d$category), period = as.character(d$period_display),
                        value = d$value)
    )
  }
  case
}

#' Drill-down choices (list_series_breakdown_values()) for every facet that
#' nests, at the first value of each level - the TypeScript port derives these
#' from the same columns.
breakdown_cases <- list()
nesting <- series_summary[series_summary$facet != "Total" & series_summary$has_breakdown_2, , drop = FALSE]
for (i in seq_len(nrow(nesting))) {
  r <- nesting[i, ]
  d1 <- list_series_breakdown_values(con, r$theme, r$series, r$facet, r$geo_level)
  breakdown_cases[[length(breakdown_cases) + 1]] <- list(
    theme = r$theme, series = r$series, facet = r$facet, geo_level = r$geo_level,
    drill_1 = NULL, expected = I(d1))
  if (length(d1) > 0 && isTRUE(r$has_breakdown_3)) {
    breakdown_cases[[length(breakdown_cases) + 1]] <- list(
      theme = r$theme, series = r$series, facet = r$facet, geo_level = r$geo_level,
      drill_1 = d1[1],
      expected = I(list_series_breakdown_values(con, r$theme, r$series, r$facet, r$geo_level, d1[1])))
  }
}

results <- lapply(cases, run_case)
by_theme <- split(results, vapply(results, `[[`, character(1), "theme"))
for (theme in names(by_theme)) {
  jsonlite::write_json(by_theme[[theme]], file.path(OUT_DIR, paste0(theme, ".json")),
                       auto_unbox = TRUE, null = "null", na = "null", digits = NA)
}
jsonlite::write_json(breakdown_cases, file.path(OUT_DIR, "breakdown_values.json"),
                     auto_unbox = TRUE, null = "null", na = "null", digits = NA)

message(sprintf("Wrote %d plot cases (%s) and %d breakdown-value cases to %s",
                length(results), paste(sprintf("%s: %d", names(by_theme), lengths(by_theme)), collapse = ", "),
                length(breakdown_cases), OUT_DIR))
