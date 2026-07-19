# Turn every downloaded raw table into tidy long + wide CSVs.
#
# Reads data-raw/manifest.csv, locates each resource's downloaded file under
# data-raw/downloads/, and runs it through R/process_utils.R:
#   - IRCC "flat" CSVs (already one row per period x dimensions) are cleaned
#     in place and pivoted wider for the wide output.
#   - IRCC "pivot" Excel workbooks (nested row/column headers, subtotal rows)
#     are parsed sheet by sheet - each sheet is its own table.
#   - IRB (rpd_decisions / rpd_1997_2021) tables are already flat with plain
#     English headers and annual granularity only - a simpler dedicated
#     parser. The RPD Data Dictionary resource is documentation, not data,
#     so it's downloaded but skipped here (status "docs").
#
# Output goes to data/processed/<dataset>/<slug>_long.csv and _wide.csv.
# Safe to re-run: a fresh run just overwrites. A summary is written to
# data-raw/process_log.csv (status: ok / error / docs, row/col counts).

library(dplyr)
source("R/ingest_utils.R")
source("R/process_utils.R")

manifest_path <- "data-raw/manifest.csv"
if (!file.exists(manifest_path)) {
  cli::cli_abort("{.file {manifest_path}} not found - run data-raw/01_build_manifest.R first")
}
manifest <- readr::read_csv(manifest_path, show_col_types = FALSE)

slugify <- function(x, max_chars = 80) {
  x <- tolower(x)
  x <- gsub("[^a-z0-9]+", "_", x)
  x <- gsub("^_+|_+$", "", x)
  substr(x, 1, max_chars)
}

find_downloaded_file <- function(dataset, resource_id) {
  dir <- fs::path("data-raw", "downloads", dataset)
  hits <- fs::dir_ls(dir, regexp = paste0("/", resource_id, "__"))
  if (length(hits) == 0) return(NA_character_)
  hits[1]
}

write_table <- function(dataset, slug, res) {
  out_dir <- fs::path("data", "processed", dataset)
  fs::dir_create(out_dir)
  readr::write_csv(res$long, fs::path(out_dir, paste0(slug, "_long.csv")))
  readr::write_csv(res$wide, fs::path(out_dir, paste0(slug, "_wide.csv")))
  tibble::tibble(
    dataset = dataset, slug = slug, status = "ok",
    n_long_rows = nrow(res$long), n_wide_rows = nrow(res$wide),
    n_wide_cols = ncol(res$wide), error = NA_character_
  )
}

irb_datasets_local <- c("rpd_decisions", "rpd_1997_2021")

# The four "French-Speaking Permanent Residents by Province/Territory and
# <X>" workbooks (Age Group / CMA / Gender / Immigration Category) each
# redundantly embed the exact same "PR - PT" (province-total-only) sheet
# alongside their own unique breakdown - confirmed identical year-by-year
# totals across all four, not just a name coincidence (see README's "Known
# limitations"). Keep that sheet from exactly one of them (the Age Group
# workbook) and skip it in the other three so it doesn't end up in the
# catalog four times over.
DUPLICATE_SHEETS <- list(
  list(
    sheet_name = "PR - PT",
    keep_from  = "2bd7ddf5-f914-4c60-8cae-87b7b3391805", # Age Group workbook
    skip_from  = c(
      "d034c26c-2dda-456d-b5ba-aeb705353131", # CMA workbook
      "f257263f-09e3-4ce7-b67d-2977981cbaf0", # Gender workbook
      "d839c522-7e47-4df6-8d5d-bf39f25f70eb"  # Immigration Category workbook
    )
  )
)

#' TRUE if `resource_id`/`sheet` is a known duplicate that should be
#' skipped in favour of its canonical copy from a sibling workbook.
is_duplicate_sheet <- function(resource_id, sheet) {
  any(vapply(DUPLICATE_SHEETS, function(d) {
    identical(sheet, d$sheet_name) && resource_id %in% d$skip_from
  }, logical(1)))
}

process_one <- function(dataset, resource_id, table_name, format) {
  path <- find_downloaded_file(dataset, resource_id)
  # prefix with a short resource-id fragment: table names are frequently
  # identical in their first ~60 characters (e.g. many "Canada - Asylum
  # Claimants by Top 25 Countries of Citizenship ..." variants differing
  # only near the end), so the name alone isn't a safe unique filename -
  # without this, different tables silently overwrote each other's output.
  base_slug <- paste0(substr(resource_id, 1, 8), "__", slugify(table_name, max_chars = 60))

  if (is.na(path)) {
    return(tibble::tibble(dataset = dataset, slug = base_slug, status = "error",
                           n_long_rows = NA_integer_, n_wide_rows = NA_integer_,
                           n_wide_cols = NA_integer_, error = "downloaded file not found"))
  }

  if (dataset %in% irb_datasets_local) {
    if (grepl("data dictionary", table_name, ignore.case = TRUE)) {
      return(tibble::tibble(dataset = dataset, slug = base_slug, status = "docs",
                             n_long_rows = NA_integer_, n_wide_rows = NA_integer_,
                             n_wide_cols = NA_integer_, error = NA_character_))
    }
    res <- tryCatch(process_flat_annual_table(path), error = function(e) e)
    if (inherits(res, "error")) {
      return(tibble::tibble(dataset = dataset, slug = base_slug, status = "error",
                             n_long_rows = NA_integer_, n_wide_rows = NA_integer_,
                             n_wide_cols = NA_integer_, error = conditionMessage(res)))
    }
    return(write_table(dataset, base_slug, res))
  }

  if (toupper(format) == "CSV") {
    res <- tryCatch(process_flat_csv(path), error = function(e) e)
    if (inherits(res, "error")) {
      return(tibble::tibble(dataset = dataset, slug = base_slug, status = "error",
                             n_long_rows = NA_integer_, n_wide_rows = NA_integer_,
                             n_wide_cols = NA_integer_, error = conditionMessage(res)))
    }
    return(write_table(dataset, base_slug, res))
  }

  sheets <- tryCatch(readxl::excel_sheets(path), error = function(e) e)
  if (inherits(sheets, "error")) {
    return(tibble::tibble(dataset = dataset, slug = base_slug, status = "error",
                           n_long_rows = NA_integer_, n_wide_rows = NA_integer_,
                           n_wide_cols = NA_integer_, error = conditionMessage(sheets)))
  }

  purrr::map(sheets, function(s) {
    sheet_slug <- if (length(sheets) == 1) base_slug else paste0(base_slug, "__", slugify(s, 30))

    if (is_duplicate_sheet(resource_id, s)) {
      return(tibble::tibble(dataset = dataset, slug = sheet_slug, status = "skipped_duplicate_sheet",
                             n_long_rows = NA_integer_, n_wide_rows = NA_integer_,
                             n_wide_cols = NA_integer_, error = NA_character_))
    }

    res <- tryCatch(process_pivot_sheet(path, s), error = function(e) e)
    if (inherits(res, "error")) {
      return(tibble::tibble(dataset = dataset, slug = sheet_slug, status = "error",
                             n_long_rows = NA_integer_, n_wide_rows = NA_integer_,
                             n_wide_cols = NA_integer_, error = conditionMessage(res)))
    }
    write_table(dataset, sheet_slug, res)
  }) |> dplyr::bind_rows()
}

cli::cli_h1("Processing {nrow(manifest)} raw tables into tidy long/wide CSVs")

results <- purrr::pmap(
  manifest |> select(dataset, resource_id, table_name, format),
  process_one,
  .progress = "Processing"
) |> bind_rows()

cli::cli_h2("Summary")
print(count(results, status))
if (any(results$status == "error")) {
  cli::cli_alert_warning("{sum(results$status == 'error')} table(s) failed:")
  print(results |> filter(status == "error") |> select(dataset, slug, error))
}

readr::write_csv(results, "data-raw/process_log.csv")
cli::cli_alert_info("Wrote data-raw/process_log.csv")
