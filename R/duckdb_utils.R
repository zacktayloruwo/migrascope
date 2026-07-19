# Normalizes every tidy long table in data/processed/ into one unified
# schema and loads it into a DuckDB database (data/immigration.duckdb) for
# the Shiny app to query.
#
# The 89 processed tables come in two shapes (see R/process_utils.R):
#  - "pivot" tables already have level_1..level_k / row_level /
#    is_row_subtotal columns describing a nested row category.
#  - "flat" tables (IRCC flat CSVs, both IRB tables) have plain named
#    dimension columns instead, with no hierarchy (is_row_subtotal is
#    always FALSE).
#
# Both are normalized into the same shape: level_1..level_5 (padded with
# NA), row_level, is_row_subtotal - so the app can treat every table
# identically. A companion `catalog` table records, per table_id, what its
# levels actually mean (real dimension names for flat tables; a
# best-effort guess parsed from the table title for pivot tables) and
# which temporal granularities it supports.

MAX_LEVELS <- 5

period_meta_cols <- c("period_year", "period_quarter", "period_month", "period_type",
                       "period_label", "is_period_subtotal")
value_cols <- c("value", "suppressed", "is_percent")

#' Best-effort extraction of dimension labels from a table title, e.g.
#' "Canada - Admissions of Permanent Residents by Province/Territory and
#' Immigration Category, January 2015 - April 2026" -> c("Province/Territory",
#' "Immigration Category"). Falls back to generic "Category Level N" labels
#' for any level beyond what the title spells out (deep sub-categories, e.g.
#' Immigration Category > Group > Component, are rarely fully named in the
#' title).
guess_level_labels <- function(title, n_levels) {
  by_part <- sub("^.*?\\bby\\b\\s*", "", title, ignore.case = TRUE)
  by_part <- sub(",?\\s*\\(.*?ranking\\).*$", "", by_part)
  by_part <- sub(",?\\s*(January|February|March|April|May|June|July|August|September|October|November|December)\\s+\\d{4}.*$", "", by_part)
  by_part <- sub(",?\\s*\\d{4}\\s*-\\s*\\d{4}.*$", "", by_part)
  by_part <- trimws(sub("\\.$", "", by_part))

  parts <- unlist(strsplit(by_part, ",|\\band\\b"))
  parts <- trimws(parts)
  parts <- parts[nzchar(parts)]

  labels <- character(n_levels)
  for (i in seq_len(n_levels)) {
    labels[i] <- if (i <= length(parts)) tools::toTitleCase(parts[i]) else paste("Category Level", i)
  }
  labels
}

#' Normalize one processed long table into the unified schema, returning
#' the reshaped facts and a one-row catalog entry.
normalize_table <- function(long, table_id, dataset, table_title) {
  is_pivot <- "level_1" %in% names(long)

  if (is_pivot) {
    level_cols <- grep("^level_[0-9]+$", names(long), value = TRUE)
    n_levels <- length(level_cols)
    labels <- guess_level_labels(table_title, n_levels)

    facts <- long |>
      dplyr::select(dplyr::all_of(level_cols), "row_level", "is_row_subtotal",
                     dplyr::all_of(period_meta_cols), dplyr::all_of(value_cols))
  } else {
    dim_cols <- setdiff(names(long), c(period_meta_cols, value_cols, "is_row_subtotal"))
    n_levels <- length(dim_cols)
    labels <- tools::toTitleCase(gsub("_", " ", dim_cols))

    facts <- long |>
      dplyr::rename_with(~ paste0("level_", seq_along(dim_cols)), dplyr::all_of(dim_cols)) |>
      dplyr::mutate(row_level = n_levels, is_row_subtotal = FALSE) |>
      dplyr::select(dplyr::starts_with("level_"), "row_level", "is_row_subtotal",
                     dplyr::all_of(period_meta_cols), dplyr::all_of(value_cols))
  }

  # some flat tables' dimension columns are numeric (e.g. a country rank) -
  # force every level_N to character so tables combine cleanly regardless
  facts <- facts |>
    dplyr::mutate(dplyr::across(dplyr::starts_with("level_"), as.character))

  # pad up to MAX_LEVELS so every table's facts share one column set
  for (i in (n_levels + 1):MAX_LEVELS) {
    facts[[paste0("level_", i)]] <- NA_character_
  }
  facts <- facts |>
    dplyr::mutate(table_id = table_id) |>
    dplyr::select("table_id", paste0("level_", 1:MAX_LEVELS), "row_level", "is_row_subtotal",
                   dplyr::all_of(period_meta_cols), dplyr::all_of(value_cols))

  has_month <- any(facts$period_type == "month")
  has_quarter <- any(facts$period_type == "quarter_total")
  has_year <- any(facts$period_type == "year")
  years <- facts$period_year[!is.na(facts$period_year)]

  # "stock" tables (e.g. "with a valid permit" snapshots) aren't additive
  # across months - same detection as R/validate_utils.R::reclassify_stock_tables()
  is_stock <- FALSE
  if (has_month && has_quarter) {
    ratio_check <- facts |>
      dplyr::filter(.data$period_type %in% c("month", "quarter_total")) |>
      dplyr::group_by(dplyr::across(dplyr::starts_with("level_")), .data$period_year, .data$period_quarter) |>
      dplyr::summarise(
        total = sum(.data$value[.data$period_type == "quarter_total"], na.rm = TRUE),
        parts = sum(.data$value[.data$period_type == "month"], na.rm = TRUE),
        .groups = "drop"
      ) |>
      dplyr::filter(.data$total > 0)
    if (nrow(ratio_check) > 20) {
      is_stock <- (mean(ratio_check$parts / ratio_check$total, na.rm = TRUE) > 2)
    }
  }

  catalog_row <- tibble::tibble(
    table_id = table_id, dataset = dataset, table_title = table_title,
    n_levels = n_levels,
    level_1_label = labels[1], level_2_label = if (n_levels >= 2) labels[2] else NA_character_,
    level_3_label = if (n_levels >= 3) labels[3] else NA_character_,
    level_4_label = if (n_levels >= 4) labels[4] else NA_character_,
    level_5_label = if (n_levels >= 5) labels[5] else NA_character_,
    has_month = has_month, has_quarter = has_quarter, has_year = has_year,
    is_stock = is_stock,
    min_year = if (length(years) > 0) min(years) else NA_integer_,
    max_year = if (length(years) > 0) max(years) else NA_integer_,
    n_rows = nrow(facts)
  )

  list(facts = facts, catalog_row = catalog_row)
}

#' Merge the two RPD (refugee decision) source tables into one continuous
#' "Refugees" theme table, spanning 1997-2026 with a single Outcome
#' breakdown (province-of-residence vs country-of-persecution are
#' different kinds of dimension across the two sources and can't be
#' unified, so the merge keeps only what both share: outcome by year).
#'
#' `rpd_decisions` (2013-2026, by country of persecution) uses
#' Positive/Negative/Other; `rpd_1997_2021` (1997-2021, by province of
#' residence) already uses Accepted/Rejected/Other - normalized here to
#' the latter vocabulary.
#'
#' For the years both sources cover (2013-2021), their outcome totals
#' don't match exactly - `rpd_decisions`' much finer country-level
#' breakdown (~200 categories) suppresses many more small cells than
#' `rpd_1997_2021`'s 13-province breakdown, and suppressed cells are
#' excluded from sums (same convention as everywhere else in this app -
#' see app.R's suppression caveat), so `rpd_decisions` totals run
#' systematically a few percent to ~30% below `rpd_1997_2021` for the same
#' year/outcome. That's an expected suppression artifact, not a data
#' error, but it means the two can't just be summed for the overlap
#' period. The merge instead takes `rpd_1997_2021` (fewer suppressed
#' cells, more complete) through 2021, and `rpd_decisions` (the only
#' source with newer data) from 2022 on - each year appears exactly once.
#' The year-by-outcome comparison is written to
#' data-raw/refugees_merge_overlap_check.csv for review.
build_refugees_table <- function(rpd_decisions_slug, rpd_1997_2021_slug) {
  col_types <- readr::cols(
    is_row_subtotal = "l", is_period_subtotal = "l",
    suppressed = "l", is_percent = "l", value = "d",
    period_year = "i", period_quarter = "i", period_month = "i",
    period_label = "c"
  )

  recent <- readr::read_csv(
    fs::path("data", "processed", "rpd_decisions", paste0(rpd_decisions_slug, "_long.csv")),
    show_col_types = FALSE, col_types = col_types
  ) |>
    dplyr::mutate(outcome = dplyr::recode(outcome, Positive = "Accepted", Negative = "Rejected"))

  historical <- readr::read_csv(
    fs::path("data", "processed", "rpd_1997_2021", paste0(rpd_1997_2021_slug, "_long.csv")),
    show_col_types = FALSE, col_types = col_types
  )

  overlap_years <- intersect(recent$period_year, historical$period_year)
  overlap_check <- dplyr::full_join(
    recent |> dplyr::filter(.data$period_year %in% overlap_years) |>
      dplyr::group_by(.data$period_year, .data$outcome) |>
      dplyr::summarise(total_rpd_decisions = sum(.data$value, na.rm = TRUE), .groups = "drop"),
    historical |> dplyr::filter(.data$period_year %in% overlap_years) |>
      dplyr::group_by(.data$period_year, .data$outcome) |>
      dplyr::summarise(total_rpd_1997_2021 = sum(.data$value, na.rm = TRUE), .groups = "drop"),
    by = c("period_year", "outcome")
  ) |>
    dplyr::mutate(
      pct_diff = round(100 * (.data$total_rpd_decisions - .data$total_rpd_1997_2021) /
                          pmax(.data$total_rpd_1997_2021, 1), 1)
    ) |>
    dplyr::arrange(.data$period_year, .data$outcome)

  readr::write_csv(overlap_check, "data-raw/refugees_merge_overlap_check.csv")
  cli::cli_alert_info(
    "Refugees merge: {nrow(overlap_check)} year x outcome rows compared for {min(overlap_years)}-{max(overlap_years)} overlap, pct_diff range [{min(overlap_check$pct_diff)}, {max(overlap_check$pct_diff)}]% (see data-raw/refugees_merge_overlap_check.csv)"
  )

  historical_max_year <- max(historical$period_year)
  combined <- dplyr::bind_rows(
    historical,
    recent |> dplyr::filter(.data$period_year > historical_max_year)
  ) |>
    dplyr::mutate(is_row_subtotal = FALSE) |>
    dplyr::select("outcome", "value", "suppressed", "is_percent", dplyr::all_of(period_meta_cols), "is_row_subtotal")

  out_dir <- fs::path("data", "processed", "refugees")
  fs::dir_create(out_dir)
  readr::write_csv(combined, fs::path(out_dir, "rpd_decisions_1997_2026_long.csv"))

  normalize_table(
    combined, "refugees/rpd_decisions_1997_2026", "refugees",
    "Refugee Protection Division (RPD) Decisions by Outcome, 1997-2026"
  )
}
