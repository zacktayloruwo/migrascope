# Internal-consistency checks for the tidy long tables in data/processed/.
#
# IRCC and IRB both round published values to the nearest 5 and suppress
# ("--") values between 0 and 5, independently at every level of a table
# (each month, each quarter total, each row subtotal, the grand total...).
# That means component values essentially never sum to *exactly* their
# published total even in a perfectly correct table - only to within
# rounding/suppression noise. Every check below therefore compares an
# observed difference against a conservative tolerance band before flagging
# an "anomaly", rather than requiring exact equality:
#
#   tolerance = ROUNDING_SLACK * (n_terms + 1) + SUPPRESSION_SLACK * n_suppressed
#
# `n_terms + 1` accounts for each component's own rounding error plus the
# total/subtotal cell's own rounding error; `n_suppressed` accounts for
# suppressed ("--") components, each of which could be as large as 5 but
# reads as NA (treated as 0 in the observed sum).
#
# Two independent kinds of consistency are checked:
#  - Column-wise, within a row: do a row's own month/quarter/year figures
#    add up internally (`validate_period_consistency()`)?
#  - Row-wise, within a period column: do a table's nested row categories
#    add up to their published subtotals and grand total
#    (`validate_row_consistency()`)? Only applies to the nested "pivot"
#    tables (those with level_1..level_k columns) - flat/already-tidy
#    tables have no row hierarchy to check.

ROUNDING_SLACK <- 2.5
SUPPRESSION_SLACK <- 5

#' Classify one total-vs-parts comparison against the rounding/suppression
#' tolerance described above.
classify_check <- function(total_value, part_values) {
  n_terms <- length(part_values)
  n_suppressed <- sum(is.na(part_values))
  sum_of_parts <- sum(part_values, na.rm = TRUE)

  if (is.na(total_value)) {
    return(tibble::tibble(
      total_value = NA_real_, sum_of_parts = sum_of_parts, n_terms = n_terms,
      n_suppressed_terms = n_suppressed, diff = NA_real_, tolerance = NA_real_,
      status = "not_checkable"
    ))
  }

  diff <- total_value - sum_of_parts
  tolerance <- ROUNDING_SLACK * (n_terms + 1) + SUPPRESSION_SLACK * n_suppressed
  status <- if (abs(diff) <= tolerance) "pass" else "anomaly"

  tibble::tibble(
    total_value = total_value, sum_of_parts = sum_of_parts, n_terms = n_terms,
    n_suppressed_terms = n_suppressed, diff = diff, tolerance = tolerance,
    status = status
  )
}

period_meta_cols <- c("period_year", "period_quarter", "period_month", "period_type",
                       "period_label", "is_period_subtotal")
value_cols <- c("value", "suppressed", "is_percent")

#' Column-wise checks, within each row: do a row's own months sum to its
#' quarter total, do its months/quarters sum to its year total? Works on
#' any long table (flat or nested pivot) - the "row identity" is just
#' whatever non-period, non-value columns the table has.
validate_period_consistency <- function(long, table_id = NA_character_) {
  id_cols <- setdiff(names(long), c(period_meta_cols, value_cols))
  if (length(id_cols) == 0) return(empty_period_result())

  d <- long |>
    dplyr::group_by(dplyr::across(dplyr::all_of(id_cols))) |>
    dplyr::mutate(row_id = dplyr::cur_group_id()) |>
    dplyr::ungroup()

  months <- d |> dplyr::filter(.data$period_type == "month")
  qtotals <- d |> dplyr::filter(.data$period_type == "quarter_total")
  ytotals <- d |> dplyr::filter(.data$period_type == "year")

  results <- list()

  # month -> quarter_total
  if (nrow(months) > 0 && nrow(qtotals) > 0) {
    results$mq <- qtotals |>
      dplyr::select("row_id", "period_year", "period_quarter", total_value = "value") |>
      dplyr::inner_join(
        months |> dplyr::select("row_id", "period_year", "period_quarter", "value"),
        by = c("row_id", "period_year", "period_quarter")
      ) |>
      dplyr::group_by(.data$row_id, .data$period_year, .data$period_quarter) |>
      dplyr::summarise(check = list(classify_check(dplyr::first(.data$total_value), .data$value)),
                        .groups = "drop") |>
      tidyr::unnest("check") |>
      dplyr::mutate(check_type = "month_to_quarter",
                     period_label = sprintf("%d Q%d", .data$period_year, .data$period_quarter))
  }

  # month -> year (only where a table publishes both, e.g. the trailing
  # in-progress-year "Total" column alongside its month breakdown)
  if (nrow(months) > 0 && nrow(ytotals) > 0) {
    results$my <- ytotals |>
      dplyr::select("row_id", "period_year", total_value = "value") |>
      dplyr::inner_join(months |> dplyr::select("row_id", "period_year", "value"),
                         by = c("row_id", "period_year")) |>
      dplyr::group_by(.data$row_id, .data$period_year) |>
      dplyr::summarise(check = list(classify_check(dplyr::first(.data$total_value), .data$value)),
                        .groups = "drop") |>
      tidyr::unnest("check") |>
      dplyr::mutate(check_type = "month_to_year",
                     period_label = sprintf("%d", .data$period_year))
  }

  # quarter_total -> year
  if (nrow(qtotals) > 0 && nrow(ytotals) > 0) {
    results$qy <- ytotals |>
      dplyr::select("row_id", "period_year", total_value = "value") |>
      dplyr::inner_join(qtotals |> dplyr::select("row_id", "period_year", "value"),
                         by = c("row_id", "period_year")) |>
      dplyr::group_by(.data$row_id, .data$period_year) |>
      dplyr::summarise(check = list(classify_check(dplyr::first(.data$total_value), .data$value)),
                        .groups = "drop") |>
      tidyr::unnest("check") |>
      dplyr::mutate(check_type = "quarter_to_year",
                     period_label = sprintf("%d", .data$period_year))
  }

  if (length(results) == 0) return(empty_period_result())

  id_lookup <- d |> dplyr::distinct(dplyr::across(dplyr::all_of(c("row_id", id_cols))))

  dplyr::bind_rows(results) |>
    dplyr::left_join(id_lookup, by = "row_id") |>
    dplyr::mutate(table_id = table_id) |>
    dplyr::select("table_id", "check_type", "period_label", dplyr::all_of(id_cols),
                  "total_value", "sum_of_parts", "n_terms", "n_suppressed_terms",
                  "diff", "tolerance", "status")
}

empty_period_result <- function() {
  tibble::tibble(table_id = character(), check_type = character(), period_label = character(),
                  total_value = double(), sum_of_parts = double(), n_terms = integer(),
                  n_suppressed_terms = integer(), diff = double(), tolerance = double(),
                  status = character())
}

#' Row-wise checks, within each period column: do a nested pivot table's
#' detail rows sum to their subtotal, and its top-level subtotals sum to
#' the grand total? Only applicable to tables with level_1..level_k
#' columns (i.e. `process_pivot_sheet()` output) - returns an empty result
#' for flat tables, which have no row hierarchy.
validate_row_consistency <- function(long, table_id = NA_character_) {
  level_cols <- grep("^level_[0-9]+$", names(long), value = TRUE)
  if (length(level_cols) == 0 || !"row_level" %in% names(long)) return(empty_row_result())
  k <- length(level_cols)

  d <- long

  subtotals <- d |> dplyr::filter(.data$is_row_subtotal)
  if (nrow(subtotals) == 0) return(empty_row_result())

  results <- list()

  # non-grand subtotals: children are rows one level deeper sharing the
  # same level_1..L path
  for (lvl in seq_len(k - 1)) {
    parents <- subtotals |>
      dplyr::filter(.data$row_level == lvl, !is.na(.data[[level_cols[1]]]))
    if (nrow(parents) == 0) next
    match_cols <- level_cols[seq_len(lvl)]

    children <- d |> dplyr::filter(.data$row_level == lvl + 1)
    if (nrow(children) == 0) next

    joined <- parents |>
      dplyr::select(dplyr::all_of(match_cols), "period_label", parent_value = "value") |>
      dplyr::inner_join(
        children |> dplyr::select(dplyr::all_of(match_cols), "period_label", "value"),
        by = c(match_cols, "period_label")
      )
    if (nrow(joined) == 0) next

    results[[paste0("lvl", lvl)]] <- joined |>
      dplyr::group_by(dplyr::across(dplyr::all_of(c(match_cols, "period_label")))) |>
      dplyr::summarise(check = list(classify_check(dplyr::first(.data$parent_value), .data$value)),
                        .groups = "drop") |>
      tidyr::unnest("check") |>
      dplyr::mutate(check_type = paste0("row_subtotal_level_", lvl))
  }

  # grand total: is_row_subtotal & the coarsest level column is NA -
  # children are every other row_level == 1 row (whatever it names)
  grand <- subtotals |> dplyr::filter(is.na(.data[[level_cols[1]]]))
  if (nrow(grand) > 0) {
    grand_children <- d |> dplyr::filter(.data$row_level == 1, !is.na(.data[[level_cols[1]]]))
    if (nrow(grand_children) > 0) {
      joined <- grand |>
        dplyr::select("period_label", parent_value = "value") |>
        dplyr::inner_join(grand_children |> dplyr::select("period_label", "value"), by = "period_label")
      results$grand <- joined |>
        dplyr::group_by(.data$period_label) |>
        dplyr::summarise(check = list(classify_check(dplyr::first(.data$parent_value), .data$value)),
                          .groups = "drop") |>
        tidyr::unnest("check") |>
        dplyr::mutate(check_type = "grand_total")
    }
  }

  if (length(results) == 0) return(empty_row_result())

  dplyr::bind_rows(results) |>
    dplyr::mutate(table_id = table_id) |>
    dplyr::select("table_id", "check_type", "period_label", dplyr::any_of(level_cols),
                  "total_value", "sum_of_parts", "n_terms",
                  "n_suppressed_terms", "diff", "tolerance", "status")
}

empty_row_result <- function() {
  tibble::tibble(table_id = character(), check_type = character(), period_label = character(),
                  total_value = double(), sum_of_parts = double(), n_terms = integer(),
                  n_suppressed_terms = integer(), diff = double(), tolerance = double(),
                  status = character())
}

#' Some tables measure a *stock* (e.g. "valid permit holders" as of a given
#' month) rather than a *flow* (permits that became effective that month).
#' Stock counts aren't additive across time - the same person holding a
#' valid permit in Jan/Feb/Mar would be triple-counted - so their "Q# Total"
#' column is not a sum of its three months, and `month_to_quarter` /
#' `quarter_to_year` checks don't apply to them at all. Rather than guessing
#' from table titles (not every stock table says "valid permit" - some
#' older legacy exports don't), this detects the pattern directly: a
#' `month_to_quarter` sum-of-parts that is consistently ~3x the published
#' total is the numerical signature of exactly this mismatch. Detected
#' checks are relabelled "not_applicable" rather than left as false-positive
#' anomalies.
#'
#' This only covers tables that publish month/quarter data in the first
#' place - an annual-only snapshot table (e.g. "on December 31st") has no
#' `month_to_quarter` checks to reclassify here at all (nothing to do,
#' correctly a no-op), but is still a stock table for every other purpose
#' (e.g. `series_facts`' stock/flow merge guard). That case is instead
#' detected from title text, since it's the only signal available when
#' there's no month/quarter ratio to compute - see
#' R/duckdb_utils.R::normalize_table()'s `STOCK_TITLE_PATTERN` fallback.
reclassify_stock_tables <- function(period_results, ratio_threshold = 2) {
  checkable <- period_results |>
    dplyr::filter(.data$check_type == "month_to_quarter", .data$status %in% c("pass", "anomaly")) |>
    dplyr::mutate(ratio = .data$sum_of_parts / .data$total_value) |>
    dplyr::filter(!is.na(.data$ratio), is.finite(.data$ratio))

  stock_tables <- checkable |>
    dplyr::group_by(.data$table_id) |>
    dplyr::summarise(mean_ratio = mean(.data$ratio), .groups = "drop") |>
    dplyr::filter(.data$mean_ratio > ratio_threshold) |>
    dplyr::pull(.data$table_id)

  period_results |>
    dplyr::mutate(status = dplyr::if_else(
      .data$table_id %in% stock_tables & .data$check_type %in% c("month_to_quarter", "quarter_to_year"),
      "not_applicable", .data$status
    ))
}
