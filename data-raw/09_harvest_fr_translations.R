# Harvests English->French text pairs for pivot-Excel and IRB source
# tables (data-raw/09_build_translations.R already covers flat CSVs, whose
# FR_* columns live in the very same downloaded file - no alignment risk
# at all there). This is Phase 3 of the bilingual rollout: standalone,
# independent of the main 01-08 pipeline - it only reads already-ingested
# English tables plus freshly-fetched French twin documents, and writes
# into the same category_translations table 09_build_translations.R
# builds, so it does not need 01/02/05/08 re-run at all.
#
# Root design: rather than re-implementing pivot-table row/column
# detection for French, this reuses R/process_utils.R's existing,
# structurally language-agnostic parser (process_pivot_sheet() locates
# the year-header row and row-label column count via digit-only year
# tokens - no English text involved) on BOTH the English and French
# workbook, then compares their row_level/is_row_subtotal SHAPE
# position-by-position. Only when that shape matches exactly are the two
# tables' row-category labels paired up (by row position) into
# translation pairs - a shape mismatch (different row count, different
# subtotal structure) means the assumption that this French document is a
# faithful structural twin of the English one doesn't hold for this table,
# so it's skipped and logged rather than guessing an alignment. A
# genuinely wrong translation is worse than a missing one.

library(dplyr)
source("R/ingest_utils.R")
source("R/process_utils.R")

FR_DIR <- "data-raw/downloads_fr"
DB_PATH <- "app/data/immigration.duckdb"
SKIPPED_LOG <- "data-raw/fr_harvest_skipped.csv"
fs::dir_create(FR_DIR)

manifest <- readr::read_csv("data-raw/manifest.csv", show_col_types = FALSE)
irb_datasets_local <- c("rpd_decisions", "rpd_1997_2021")

slugify <- function(x, max_chars = 60) {
  x <- tolower(x); x <- gsub("[^a-z0-9]+", "_", x); x <- gsub("^_+|_+$", "", x)
  substr(x, 1, max_chars)
}

# ---- resolve the French twin resource for one manifest row ----------------
dataset_ckan_ids <- c(ircc_datasets, irb_datasets)
pkg_cache <- new.env()
get_pkg <- function(dataset_id) {
  if (is.null(pkg_cache[[dataset_id]])) {
    pkg_cache[[dataset_id]] <- fetch_ckan_package(dataset_id)
  }
  pkg_cache[[dataset_id]]
}

#' CKAN's resource `name` field is identical text for the English and
#' French resource of the same table (confirmed live - only the
#' `language` tag and the file itself differ), so matching by exact name
#' is safe and precise, no title-similarity heuristics needed.
#'
#' rpd_decisions is the one exception: build_rpd_decisions_manifest()
#' (R/ingest_utils.R) renames its manifest table_name to a fixed
#' "Refugee Protection Division (RPD) Decisions" (dropping the
#' quarter-specific suffix every raw CKAN resource actually has, e.g.
#' "Refugee Protection Division Decisions 2026 Q2"), so an exact-name
#' match against the live CKAN resources never succeeds for it - instead,
#' find the EN resource this manifest row's resource_id actually points
#' to, extract its (year, quarter) from its own raw name, and find the FR
#' resource sharing that same (year, quarter).
find_fr_resource <- function(dataset, table_name, preferred_format, resource_id = NULL) {
  did <- dataset_ckan_ids[[dataset]]
  if (is.null(did)) return(NULL)
  pkg <- tryCatch(get_pkg(did), error = function(e) NULL)
  if (is.null(pkg)) return(NULL)

  if (identical(dataset, "rpd_decisions") && !is.null(resource_id)) {
    en_res <- purrr::keep(pkg$result$resources, function(r) identical(r$id, resource_id))
    if (length(en_res) == 0) return(NULL)
    en_name <- en_res[[1]]$name
    yq <- regmatches(en_name, regexec("(\\d{4})\\s*Q([1-4])", en_name))[[1]]
    if (length(yq) == 0) return(NULL)
    yq_pattern <- sprintf("%s\\s*Q%s", yq[2], yq[3])
    candidates <- purrr::keep(pkg$result$resources, function(r) {
      "fr" %in% unlist(r$language) && grepl(yq_pattern, r$name)
    })
    if (length(candidates) == 0) return(NULL)
    return(candidates[[1]])
  }

  candidates <- purrr::keep(pkg$result$resources, function(r) {
    "fr" %in% unlist(r$language) && identical(r$name, table_name)
  })
  if (length(candidates) == 0) return(NULL)
  fmts <- vapply(candidates, function(r) toupper(r$format %||% ""), character(1))
  pick <- which(fmts == toupper(preferred_format))
  if (length(pick) == 0) pick <- 1L
  candidates[[pick[1]]]
}

download_fr_resource <- function(dataset, resource) {
  ext <- tolower(resource$format)
  dest_dir <- fs::path(FR_DIR, dataset)
  fs::dir_create(dest_dir)
  dest <- fs::path(dest_dir, paste0(substr(resource$id, 1, 8), "__", slugify(resource$name), ".", ext))
  if (!fs::file_exists(dest)) {
    tryCatch({
      httr2::request(resource$url) |>
        httr2::req_user_agent("canadian-immigration-statistics ingest pipeline") |>
        httr2::req_perform(path = dest)
    }, error = function(e) {
      cli::cli_alert_warning("Could not download FR twin for {dataset}/{resource$name}: {conditionMessage(e)}")
      return(NULL)
    })
  }
  if (fs::file_exists(dest)) dest else NA_character_
}

find_downloaded_en_file <- function(dataset, resource_id) {
  dir <- fs::path("data-raw", "downloads", dataset)
  hits <- fs::dir_ls(dir, regexp = paste0("/", resource_id, "__"))
  if (length(hits) == 0) return(NA_character_)
  hits[1]
}

# ---- shared harvesting helpers ---------------------------------------------

skipped <- list()
log_skip <- function(table_id, reason) {
  skipped[[length(skipped) + 1]] <<- tibble::tibble(table_id = table_id, reason = reason)
}

BREAKDOWN_CONTEXTS <- c("breakdown_1", "breakdown_2", "breakdown_3", "facet")

#' Build translation pairs from two already-parsed `long` tables (one EN,
#' one FR) that share the exact same row_level/is_row_subtotal shape -
#' pairs every level_N cell position-by-position, keeping only genuinely
#' distinct, non-blank text on both sides.
harvest_pairs_from_long <- function(en_long, fr_long, table_id) {
  level_cols <- grep("^level_", names(en_long), value = TRUE)
  purrr::map_dfr(level_cols, function(col) {
    en_vals <- en_long[[col]]
    fr_vals <- fr_long[[col]]
    tibble::tibble(en_text = en_vals, fr_text = fr_vals) |>
      dplyr::filter(!is.na(.data$en_text), !is.na(.data$fr_text),
                     nzchar(.data$en_text), nzchar(.data$fr_text),
                     .data$en_text != .data$fr_text | TRUE) |>  # keep even if identical (e.g. place names, numerals)
      dplyr::distinct() |>
      dplyr::mutate(table_id = table_id)
  }) |> tidyr::crossing(context = BREAKDOWN_CONTEXTS) |>
    dplyr::relocate("en_text", "fr_text", "table_id", "context")
}

#' Matching row_level/is_row_subtotal SHAPE alone isn't sufficient proof
#' that row N of the English parse and row N of the French parse are the
#' same real-world category in the same order - two tables can have an
#' identical nesting structure (same row count, same subtotal positions)
#' while actually listing categories in a different order (found via a
#' handful of "Top 25 Countries" and permanent_residents tables where
#' shape matched perfectly but "Algeria" ended up paired with "Albania"/
#' "South Africa" from unrelated rows). The `value` column is genuinely
#' language-neutral and row-position-comparable, so it's the real proof:
#' if the same row position doesn't carry the same number in both
#' languages for the vast majority of (period, row) cells, the row order
#' assumption doesn't hold for this table, regardless of how well the
#' structural shape lined up.
shapes_match <- function(en_long, fr_long) {
  if (nrow(en_long) != nrow(fr_long)) return(FALSE)
  if (!identical(en_long$row_level, fr_long$row_level)) return(FALSE)
  if (!identical(en_long$is_row_subtotal, fr_long$is_row_subtotal)) return(FALSE)

  both_present <- !is.na(en_long$value) & !is.na(fr_long$value)
  if (sum(both_present) < 20) return(TRUE)  # too little overlap to judge either way
  mismatch_rate <- mean(en_long$value[both_present] != fr_long$value[both_present])
  mismatch_rate < 0.01
}

# ---- pivot Excel tables -----------------------------------------------------

pivot_rows <- manifest |>
  dplyr::filter(toupper(.data$format) %in% c("XLSX", "XLS"), !.data$dataset %in% irb_datasets_local)

cli::cli_h1("Harvesting FR translations from {nrow(pivot_rows)} pivot Excel resources")

all_pairs <- list()

for (i in seq_len(nrow(pivot_rows))) {
  row <- pivot_rows[i, ]
  en_path <- find_downloaded_en_file(row$dataset, row$resource_id)
  if (is.na(en_path)) next

  fr_resource <- find_fr_resource(row$dataset, row$table_name, row$format, row$resource_id)
  if (is.null(fr_resource)) {
    log_skip(paste(row$dataset, row$table_name, sep = "/"), "no FR resource found on CKAN")
    next
  }
  fr_path <- download_fr_resource(row$dataset, fr_resource)
  if (is.na(fr_path)) {
    log_skip(paste(row$dataset, row$table_name, sep = "/"), "FR download failed")
    next
  }

  en_sheets <- tryCatch(readxl::excel_sheets(en_path), error = function(e) character(0))
  fr_sheets <- tryCatch(readxl::excel_sheets(fr_path), error = function(e) character(0))
  base_slug <- paste0(substr(row$resource_id, 1, 8), "__", slugify(row$table_name, 60))

  for (j in seq_along(en_sheets)) {
    s_en <- en_sheets[j]
    # Sheets are matched by position, not name (French sheet tab names may
    # differ from English) - both workbooks are assumed to enumerate the
    # same sheets in the same order, since they're the same underlying
    # export just translated; a row-shape mismatch below would catch it
    # if that assumption ever breaks for a specific table.
    if (j > length(fr_sheets)) {
      log_skip(paste(row$dataset, base_slug, s_en, sep = "/"), "FR workbook has fewer sheets")
      next
    }
    s_fr <- fr_sheets[j]
    slug <- if (length(en_sheets) == 1) base_slug else paste0(base_slug, "__", slugify(s_en, 30))
    table_id <- paste(row$dataset, slug, sep = "/")

    en_res <- tryCatch(process_pivot_sheet(en_path, s_en), error = function(e) e)
    fr_res <- tryCatch(process_pivot_sheet(fr_path, s_fr), error = function(e) e)
    if (inherits(en_res, "error") || inherits(fr_res, "error")) {
      log_skip(table_id, "could not parse EN or FR sheet")
      next
    }
    if (!shapes_match(en_res$long, fr_res$long)) {
      log_skip(table_id, "EN/FR row shape or value mismatch (structure and/or per-row values disagree)")
      next
    }
    all_pairs[[table_id]] <- harvest_pairs_from_long(en_res$long, fr_res$long, table_id)
  }
}

# ---- IRB flat annual tables --------------------------------------------------

irb_rows <- manifest |> dplyr::filter(.data$dataset %in% irb_datasets_local)
cli::cli_h1("Harvesting FR translations from {nrow(irb_rows)} IRB resources")

read_irb_raw <- function(path) {
  ext <- tolower(tools::file_ext(path))
  if (ext == "csv") {
    readr::read_csv(path, col_types = readr::cols(.default = "c"),
                     locale = readr::locale(encoding = "latin1"), progress = FALSE, show_col_types = FALSE)
  } else {
    readxl::read_excel(path, sheet = 1, col_types = "text")
  }
}

for (i in seq_len(nrow(irb_rows))) {
  row <- irb_rows[i, ]
  if (grepl("data dictionary", row$table_name, ignore.case = TRUE)) next
  en_path <- find_downloaded_en_file(row$dataset, row$resource_id)
  if (is.na(en_path)) next

  fr_resource <- find_fr_resource(row$dataset, row$table_name, row$format, row$resource_id)
  if (is.null(fr_resource)) {
    log_skip(paste(row$dataset, row$table_name, sep = "/"), "no FR resource found on CKAN")
    next
  }
  fr_path <- download_fr_resource(row$dataset, fr_resource)
  if (is.na(fr_path)) {
    log_skip(paste(row$dataset, row$table_name, sep = "/"), "FR download failed")
    next
  }

  base_slug <- paste0(substr(row$resource_id, 1, 8), "__", slugify(row$table_name, 60))
  table_id <- paste(row$dataset, base_slug, sep = "/")

  en_raw <- tryCatch(read_irb_raw(en_path), error = function(e) e)
  fr_raw <- tryCatch(read_irb_raw(fr_path), error = function(e) e)
  if (inherits(en_raw, "error") || inherits(fr_raw, "error")) {
    log_skip(table_id, "could not read EN or FR file")
    next
  }
  if (nrow(en_raw) != nrow(fr_raw)) {
    log_skip(table_id, "EN/FR row count mismatch")
    next
  }

  en_value_col <- names(en_raw)[toupper(names(en_raw)) == "TOTAL"][1]
  en_year_col <- names(en_raw)[toupper(names(en_raw)) == "YEAR"][1]
  fr_value_col <- names(fr_raw)[length(names(fr_raw))]  # Total is always the last column in both languages
  if (is.na(en_value_col) || is.na(en_year_col)) {
    log_skip(table_id, "could not find Year/Total columns in EN file")
    next
  }
  # Position-based consistency check before trusting row alignment: the
  # numeric Total column (position-matched, language-neutral) should
  # agree row-for-row if the two files really do list rows in the same
  # order - not proof of correct alignment on its own, but a cheap,
  # meaningful sanity check given no other language-neutral join key
  # (Year alone repeats many times across categories).
  en_total <- suppressWarnings(as.numeric(gsub(",", "", en_raw[[en_value_col]])))
  fr_total <- suppressWarnings(as.numeric(gsub(",", "", fr_raw[[fr_value_col]])))
  mismatch_rate <- mean(!is.na(en_total) & !is.na(fr_total) & en_total != fr_total)
  if (is.na(mismatch_rate) || mismatch_rate > 0.01) {
    log_skip(table_id, sprintf("EN/FR Total column values disagree (%.1f%% mismatched) - row order assumption unsafe", mismatch_rate * 100))
    next
  }

  en_dim_cols <- setdiff(names(en_raw), c(en_year_col, en_value_col))
  fr_dim_cols <- setdiff(names(fr_raw), fr_value_col)[seq_along(en_dim_cols)]
  pairs <- purrr::map_dfr(seq_along(en_dim_cols), function(k) {
    tibble::tibble(en_text = en_raw[[en_dim_cols[k]]], fr_text = fr_raw[[fr_dim_cols[k]]]) |>
      dplyr::filter(!is.na(.data$en_text), !is.na(.data$fr_text), nzchar(.data$en_text), nzchar(.data$fr_text)) |>
      dplyr::distinct()
  }) |> dplyr::mutate(table_id = table_id) |>
    tidyr::crossing(context = BREAKDOWN_CONTEXTS) |>
    dplyr::relocate("en_text", "fr_text", "table_id", "context")
  all_pairs[[table_id]] <- pairs
}

# ---- write skipped log + hand off to 09_build_translations.R's bake step --

if (length(skipped) > 0) {
  readr::write_csv(dplyr::bind_rows(skipped), SKIPPED_LOG)
  cli::cli_alert_warning("{length(skipped)} table(s) skipped - see {SKIPPED_LOG}")
}

pairs_all <- dplyr::bind_rows(all_pairs)
if (nrow(pairs_all) == 0) {
  cli::cli_alert_warning("No pivot/IRB translation pairs harvested")
} else {
  fs::dir_create("data-raw")
  readr::write_csv(pairs_all, "data-raw/fr_harvest_pivot_irb_pairs.csv")
  cli::cli_alert_success("Harvested {nrow(pairs_all)} pivot/IRB translation rows -> data-raw/fr_harvest_pivot_irb_pairs.csv (re-run data-raw/09_build_translations.R to fold these in)")
}
