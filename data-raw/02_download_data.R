# Download every resource listed in data-raw/manifest.csv into
# data-raw/downloads/<dataset>/<resource_id>__<slug>.<ext>.
#
# Safe to re-run monthly: before touching the network, each resource's CKAN
# `metadata_modified` timestamp (captured in the manifest as
# `last_modified_ckan`) is compared against the value recorded the last time
# it was successfully downloaded (data-raw/download_log.csv). If it's
# unchanged and the local file still exists, the download is skipped
# entirely. Otherwise the file is fetched to a temp path and hash-compared
# against the existing copy as a second safety net (CKAN's timestamp can lag
# or a resource can be replaced without it changing), so re-running when
# nothing has actually changed leaves your working tree untouched either way.

library(dplyr)
source("R/ingest_utils.R")

manifest_path <- "data-raw/manifest.csv"
if (!file.exists(manifest_path)) {
  cli::cli_abort("{.file {manifest_path}} not found - run data-raw/01_build_manifest.R first")
}

manifest <- readr::read_csv(manifest_path, show_col_types = FALSE,
                             col_types = readr::cols(last_modified_ckan = "c"))

prior_log_path <- "data-raw/download_log.csv"
prior_state <- if (file.exists(prior_log_path)) {
  prior_raw <- readr::read_csv(prior_log_path, show_col_types = FALSE,
                                col_types = readr::cols(last_modified_ckan = "c"))
  if (!"last_modified_ckan" %in% names(prior_raw)) {
    prior_raw$last_modified_ckan <- NA_character_
  }
  prior_raw |>
    filter(.data$status != "error") |>
    select("resource_id", "dest_file", "last_modified_ckan") |>
    distinct(.data$resource_id, .keep_all = TRUE)
} else {
  tibble::tibble(resource_id = character(), dest_file = character(),
                  last_modified_ckan = character())
}

slugify <- function(x, max_chars = 80) {
  x <- tolower(x)
  x <- gsub("[^a-z0-9]+", "_", x)
  x <- gsub("^_+|_+$", "", x)
  substr(x, 1, max_chars)
}

download_one <- function(dataset, resource_id, table_name, format, url, last_modified_ckan) {
  dest_dir <- fs::path("data-raw", "downloads", dataset)
  fs::dir_create(dest_dir)

  ext <- tolower(format)
  dest_file <- fs::path(dest_dir, paste0(resource_id, "__", slugify(table_name)), ext = ext)

  prior <- prior_state |> filter(.data$resource_id == .env$resource_id)
  if (nrow(prior) == 1 && !is.na(prior$last_modified_ckan) &&
      identical(prior$last_modified_ckan, last_modified_ckan) &&
      fs::file_exists(prior$dest_file)) {
    return(tibble::tibble(
      dataset = dataset, resource_id = resource_id, table_name = table_name,
      dest_file = as.character(prior$dest_file), status = "skipped_unchanged",
      last_modified_ckan = last_modified_ckan
    ))
  }

  tmp_file <- fs::file_temp(ext = ext)
  # IRCC occasionally publishes URLs with literal, un-encoded spaces.
  url <- utils::URLencode(url)

  status <- tryCatch(
    {
      httr2::request(url) |>
        httr2::req_user_agent("canadian-immigration-statistics ingest pipeline") |>
        httr2::req_retry(max_tries = 3) |>
        httr2::req_perform(path = tmp_file)
      "downloaded"
    },
    error = function(e) {
      cli::cli_alert_danger("Failed: {table_name} ({e$message})")
      "error"
    }
  )

  if (status == "error") {
    return(tibble::tibble(
      dataset = dataset, resource_id = resource_id, table_name = table_name,
      dest_file = as.character(dest_file), status = "error",
      last_modified_ckan = last_modified_ckan
    ))
  }

  new_hash <- rlang::hash_file(tmp_file)
  if (fs::file_exists(dest_file) && rlang::hash_file(dest_file) == new_hash) {
    fs::file_delete(tmp_file)
    status <- "unchanged"
  } else if (fs::file_exists(dest_file)) {
    fs::file_move(tmp_file, dest_file)
    status <- "updated"
  } else {
    fs::file_move(tmp_file, dest_file)
    status <- "new"
  }

  tibble::tibble(
    dataset = dataset, resource_id = resource_id, table_name = table_name,
    dest_file = as.character(dest_file), status = status,
    last_modified_ckan = last_modified_ckan
  )
}

cli::cli_h1("Downloading {nrow(manifest)} IRCC/IRB data tables")

results <- purrr::pmap(
  manifest |> select(dataset, resource_id, table_name, format, url, last_modified_ckan),
  download_one,
  .progress = "Downloading"
) |> bind_rows()

cli::cli_h2("Summary")
print(count(results, status))

readr::write_csv(results, "data-raw/download_log.csv")
cli::cli_alert_info("Wrote data-raw/download_log.csv")

if (any(results$status == "error")) {
  cli::cli_alert_warning("{sum(results$status == 'error')} table(s) failed to download - see log above")
}
