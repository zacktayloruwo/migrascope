# Run internal-consistency checks (R/validate_utils.R) against every tidy
# long table in data/processed/, and write the combined results for the
# Quarto data-quality report to read.
#
# Two independent check families (see R/validate_utils.R for the tolerance
# methodology):
#   - validate_period_consistency(): column-wise, within a row - do months
#     sum to their quarter total, quarters/months to their year total?
#   - validate_row_consistency(): row-wise, within a period column - do a
#     nested pivot table's detail rows sum to their subtotal, and its
#     subtotals to the grand total? (nested pivot tables only)
#
# Output: data-raw/validation_period_results.csv/.rds and
# data-raw/validation_row_results.csv/.rds, plus a printed summary.

library(dplyr)
source("R/validate_utils.R")

long_files <- fs::dir_ls("data/processed", regexp = "_long\\.csv$", recurse = TRUE)
if (length(long_files) == 0) {
  cli::cli_abort("No processed long tables found - run data-raw/03_process_tables.R first")
}

cli::cli_h1("Validating {length(long_files)} processed tables")

read_long <- function(path) {
  readr::read_csv(path, show_col_types = FALSE,
                   col_types = readr::cols(
                     is_row_subtotal = "l", is_period_subtotal = "l",
                     suppressed = "l", is_percent = "l",
                     period_year = "i", period_quarter = "i", period_month = "i",
                     row_level = "i", value = "d",
                     # annual-only tables' period_label is just digits (e.g.
                     # "2013"), which readr's type guesser would otherwise
                     # read as numeric - forcing character keeps every
                     # table's period_label type consistent for bind_rows()
                     period_label = "c"
                   ))
}

table_id_from_path <- function(path) {
  parts <- fs::path_split(path)[[1]]
  n <- length(parts)
  paste(parts[n - 1], sub("_long\\.csv$", "", parts[n]), sep = "/")
}

results <- purrr::map(long_files, function(f) {
  table_id <- table_id_from_path(f)
  t0 <- Sys.time()
  long <- tryCatch(read_long(f), error = function(e) e)
  if (inherits(long, "error")) {
    cli::cli_alert_danger("Could not read {f}: {conditionMessage(long)}")
    return(list(period = empty_period_result(), row = empty_row_result()))
  }
  out <- list(
    period = validate_period_consistency(long, table_id),
    row = validate_row_consistency(long, table_id)
  )
  elapsed <- round(as.numeric(Sys.time() - t0, units = "secs"), 1)
  cli::cli_alert_info("{table_id} ({nrow(long)} rows): {elapsed}s")
  out
})

period_results <- purrr::map(results, "period") |> bind_rows()
row_results <- purrr::map(results, "row") |> bind_rows()

period_results_raw <- period_results
period_results <- reclassify_stock_tables(period_results)
reclassified <- period_results |> filter(status == "not_applicable")
if (nrow(reclassified) > 0) {
  n_reclassified <- nrow(reclassified)
  n_stock_tables <- n_distinct(reclassified$table_id)
  cli::cli_alert_info(
    "Reclassified {n_reclassified} month_to_quarter/quarter_to_year checks as not_applicable ({n_stock_tables} 'stock' tables - see R/validate_utils.R::reclassify_stock_tables())"
  )
}

cli::cli_h2("Period consistency (column-wise, within a row)")
print(count(period_results, check_type, status))

cli::cli_h2("Row consistency (row-wise, within a period)")
print(count(row_results, check_type, status))

fs::dir_create("data-raw")
readr::write_csv(period_results, "data-raw/validation_period_results.csv")
readr::write_csv(row_results, "data-raw/validation_row_results.csv")
saveRDS(period_results, "data-raw/validation_period_results.rds")
saveRDS(row_results, "data-raw/validation_row_results.rds")

cli::cli_alert_info("Wrote data-raw/validation_{{period,row}}_results.{{csv,rds}}")

n_anomalies <- sum(period_results$status == "anomaly") + sum(row_results$status == "anomaly")
if (n_anomalies > 0) {
  cli::cli_alert_warning("{n_anomalies} anomalies flagged across all tables - see reports/data_quality_report.pdf")
} else {
  cli::cli_alert_success("No anomalies flagged (beyond rounding/suppression tolerance)")
}
